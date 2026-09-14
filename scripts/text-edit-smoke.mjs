import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-text-edit-'));
const docs = path.join(root, 'Documents');
const names = ['网页.html', '带格式.rtf', '说明.md', '配置.json', '脚本.py', 'README', "自定义 ' $(literal).custom", '普通.txt'];
await fs.mkdir(docs);
await fs.mkdir(path.join(docs, '文件夹'));
for (const name of names) await fs.writeFile(path.join(docs, name), 'Temporary text editor fixture');
const app = await electron.launch({
  ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }),
  env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' },
});
try {
  const page = await app.firstWindow(); page.setDefaultTimeout(15000);
  const row = name => page.getByRole('option', { name, exact: true });
  await row(names[0]).waitFor();
  // Keep external apps closed: verify the real IPC handler's exact launch arguments.
  await app.evaluate(() => {
    globalThis.textEditCalls = [];
    process.getBuiltinModule('child_process').execFile = (file, args, callback) => {
      globalThis.textEditCalls.push({ file, args }); callback(null, '', '');
    };
  });
  for (const name of names) {
    await row(name).click({ button: 'right' });
    await page.getByRole('menuitem', { name: '使用文本编辑', exact: true }).click();
    await page.waitForFunction(p => JSON.parse(localStorage.getItem('recent') || '[]')[0] === p, path.join(docs, name));
    assert.deepEqual(await app.evaluate(() => globalThis.textEditCalls.at(-1)), { file: '/usr/bin/open', args: ['-n', '-b', 'com.apple.TextEdit', path.join(docs, name), '--args', '-IgnoreHTML', 'YES', '-IgnoreRichText', 'YES'] });
  }
  await row('文件夹').click({ button: 'right' });
  assert.equal(await page.getByRole('menuitem', { name: '使用文本编辑', exact: true }).count(), 0);
  await page.keyboard.press('Escape');
  await row(names[0]).click(); await page.keyboard.press('Control+a');
  await row(names[0]).click({ button: 'right' });
  assert.equal(await page.getByRole('menuitem', { name: '使用文本编辑', exact: true }).isDisabled(), true);
  await page.keyboard.press('Escape');
  const selected = names.slice(0, 2).map(name => path.join(docs, name));
  await page.evaluate(paths => window.explorer.openWith(paths, 'textedit'), selected);
  assert.deepEqual(await app.evaluate(() => globalThis.textEditCalls.at(-1).args), ['-n', '-b', 'com.apple.TextEdit', ...selected, '--args', '-IgnoreHTML', 'YES', '-IgnoreRichText', 'YES']);
  const count = await app.evaluate(() => globalThis.textEditCalls.length);
  for (const [files, editor] of [[[], 'textedit'], [[docs], 'textedit'], [[selected[0]], 'invalid'], [['relative.txt'], 'textedit']]) {
    assert.equal(await page.evaluate(async ([paths, mode]) => { try { await window.explorer.openWith(paths, mode); return false; } catch { return true; } }, [files, editor]), true);
  }
  assert.equal(await app.evaluate(() => globalThis.textEditCalls.length), count);
  await app.evaluate(() => { process.getBuiltinModule('child_process').execFile = (_file, _args, callback) => callback(new Error('TextEdit launch fixture failed')); });
  await row(names[0]).click(); await row(names[0]).click({ button: 'right' });
  await page.getByRole('menuitem', { name: '使用文本编辑', exact: true }).click();
  await page.getByText('TextEdit launch fixture failed', { exact: true }).waitFor();
  for (const name of names) assert.equal(await fs.readFile(path.join(docs, name), 'utf8'), 'Temporary text editor fixture');
  console.log('PASS: text edit menu, arbitrary extensions, literal arguments, multi-file launch, folder exclusion, IPC validation, launch errors, unchanged originals (external launch mocked).');
} finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
