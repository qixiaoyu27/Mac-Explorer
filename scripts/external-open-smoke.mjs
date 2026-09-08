import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-external-'));
const docs = path.join(root, 'Documents');
const folder = path.join(root, "中文 $(test) ' 文件夹");
await fs.mkdir(docs); await fs.mkdir(folder);
const preserved = path.join(docs, '保持原状.txt');
await fs.writeFile(preserved, 'Keep this file');
const file = path.join(folder, '说明.txt');
const hidden = path.join(folder, '.隐藏.txt');
const bundle = path.join(folder, '示例.app');
await fs.writeFile(file, 'External open fixture');
await fs.writeFile(hidden, 'Hidden fixture'); await fs.mkdir(bundle);
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
let page = await app.firstWindow();
page.setDefaultTimeout(15_000);
const errors = [];
page.on('pageerror', error => errors.push(error.message));
const selected = name => page.getByRole('option', { name, exact: true });
const emit = paths => app.evaluate(({ app }, paths) => {
  for (const value of paths) app.emit('open-file', { preventDefault() {} }, value);
}, paths);
const waitSelected = async name => {
  await selected(name).waitFor();
  await page.waitForFunction(name => [...document.querySelectorAll('[role=option]')].some(el => el.getAttribute('aria-label') === name && el.getAttribute('aria-selected') === 'true'), name);
};
try {
  await page.getByRole('tab', { name: '文档', exact: true }).waitFor();
  await app.evaluate(({ shell }) => { shell.openPath = async () => { throw new Error('External reveal must not open or execute files'); }; });
  await emit([file]); await waitSelected('说明.txt'); console.log('file passed');
  assert.equal(await page.getByRole('tab').count(), 2);
  await emit([hidden, file]); await waitSelected('.隐藏.txt'); await waitSelected('说明.txt');
  assert.equal(await page.evaluate(() => localStorage.getItem('hidden')), 'false');
  assert.equal(await page.getByRole('tab').count(), 2);
  console.log('multi passed'); await emit([bundle]); await waitSelected('示例.app');
  await emit([docs]);
  await page.waitForFunction(() => document.querySelector('[role=tab][aria-selected=true]')?.textContent === '文档');
  console.log('folder passed');
  await selected('保持原状.txt').click(); await page.keyboard.press('Delete');
  await page.getByRole('dialog').waitFor();
  await emit([file]);
  // Use a confirmation dialog: inline rename intentionally saves on blur,
  // and macOS activation can blur its input before the open request arrives.
  await page.waitForTimeout(200);
  assert.equal(await page.getByRole('dialog').count(), 1);
  assert.equal(await page.getByRole('tab', { name: '文档', exact: true }).getAttribute('aria-selected'), 'true');
  await page.keyboard.press('Escape'); await waitSelected('说明.txt');
  await emit(['relative', '/bad\0path', path.join(root, 'missing'), hidden]); await waitSelected('.隐藏.txt');
  assert.equal(await page.getByRole('tab').count(), 2);
  // A document arriving with no renderer must survive creation of a fresh window.
  const nextWindow = app.waitForEvent('window');
  await app.evaluate(async ({ app, BrowserWindow }, file) => {
    app.removeAllListeners('window-all-closed');
    const window = BrowserWindow.getAllWindows()[0];
    await new Promise(resolve => { window.once('closed', resolve); window.close(); });
    app.emit('open-file', { preventDefault() {} }, file);
  }, file);
  page = await nextWindow;
  await waitSelected('说明.txt');
  if (process.env.EXPLORER_NATIVE_BUNDLE) {
    await promisify(execFile)('/usr/bin/open', ['-a', process.env.EXPLORER_NATIVE_BUNDLE, hidden]);
    await waitSelected('.隐藏.txt');
    console.log('Actual LaunchServices open -a delivery passed');
  }
  assert.equal(await fs.readFile(preserved, 'utf8'), 'Keep this file');
  assert.equal(await fs.readFile(file, 'utf8'), 'External open fixture');
  assert.equal(await fs.readFile(hidden, 'utf8'), 'Hidden fixture');
  assert.deepEqual(errors, []);
  console.log('External open: folder/file/package, hidden reveal, multi-file selection, tab reuse, confirmation-dialog deferral, invalid paths and pre-renderer queue passed');
} catch (error) { console.error(error); if (!page.isClosed()) console.error(await page.locator('body').innerText()); throw error; } finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
