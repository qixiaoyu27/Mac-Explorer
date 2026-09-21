import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-trash-browser-'));
await fs.mkdir(path.join(root, 'Documents'));
await fs.mkdir(path.join(root, '.Trash', '旧文件夹'), { recursive: true });
await fs.writeFile(path.join(root, '.Trash', '旧文件夹', '保留.txt'), 'preserved');
await fs.writeFile(path.join(root, '.Trash', '本机.txt'), 'home');
const external = path.join(root, 'Volumes', '外接磁盘', '.Trashes', String(process.getuid()));
await fs.mkdir(external, { recursive: true }); await fs.writeFile(path.join(external, '外接.txt'), 'external');
const app = await electron.launch({ args: [process.cwd()], env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  const page = await app.firstWindow(); page.setDefaultTimeout(15000);
  const shortcut = page.locator('.sidebar').getByRole('button', { name: '回收站', exact: true });
  const row = name => page.getByRole('option', { name, exact: true });
  await shortcut.click(); await row('本机.txt').waitFor(); await row('外接.txt').waitFor();
  assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isDisabled(), true);
  await row('本机.txt').click();
  for (const name of ['重命名 (Return)', '移到回收站 (⌘⌫)', '剪切 (Ctrl+X)']) assert.equal(await page.getByRole('button', { name, exact: true }).isDisabled(), true);
  await page.keyboard.press('Enter'); assert.equal(await page.getByLabel('名称', { exact: true }).count(), 0);
  await page.keyboard.press('Meta+Backspace'); assert.equal(await page.getByRole('dialog').count(), 0);
  await row('旧文件夹').dblclick(); await row('保留.txt').waitFor();
  await page.keyboard.press('Backspace'); await row('本机.txt').waitFor();
  await page.keyboard.press('Meta+['); await row('保留.txt').waitFor();
  await page.keyboard.press('Meta+]'); await row('本机.txt').waitFor();
  await shortcut.click({ button: 'right' }); await page.getByRole('menuitem', { name: '从快速访问取消固定', exact: true }).click();
  assert.equal(await shortcut.count(), 0);
  await app.evaluate(({ ipcMain }) => {
    const bootstrap = ipcMain._invokeHandlers.get('bootstrap');
    ipcMain.removeHandler('bootstrap');
    ipcMain.handle('bootstrap', async (...args) => ({ ...await bootstrap(...args), initialPath: undefined }));
  });
  await page.reload(); await page.locator('.file-content[aria-busy=false]').waitFor(); assert.equal(await shortcut.count(), 0);
  await page.getByRole('tab', { name: '回收站', exact: true }).click(); await row('本机.txt').waitFor();
  await page.locator('.file-content').click({ button: 'right' }); await page.getByRole('menuitem', { name: '固定到快速访问', exact: true }).click(); await shortcut.waitFor();
  await page.screenshot({ path: 'artifacts/trash-browser-fixture.png' });
  assert.equal(await fs.readFile(path.join(root, '.Trash', '本机.txt'), 'utf8'), 'home');
  assert.equal(await fs.readFile(path.join(root, '.Trash', '旧文件夹', '保留.txt'), 'utf8'), 'preserved');
  await app.evaluate(({ ipcMain }) => {
    ipcMain.removeHandler('list-trash');
    ipcMain.handle('list-trash', () => ({ entries: [], roots: [], unavailable: ['fixture'] }));
  });
  await page.getByRole('button', { name: '刷新 (F5)', exact: true }).click();
  await page.getByRole('alert').filter({ hasText: '部分回收站无法读取' }).waitFor();
  assert.equal(await page.getByText('回收站为空', { exact: true }).count(), 0);
  await app.evaluate(({ shell }) => {
    globalThis.openedSettingsURLs = [];
    shell.openExternal = async url => { globalThis.openedSettingsURLs.push(url); };
  });
  await page.getByRole('button', { name: '前往设置', exact: true }).click();
  assert.deepEqual(await app.evaluate(() => globalThis.openedSettingsURLs), ['x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles']);
  await page.getByRole('alert').filter({ hasText: '部分回收站无法读取' }).waitFor();
  await page.screenshot({ path: 'artifacts/trash-permission-settings-fixture.png' });
  await app.evaluate(({ shell }) => { shell.openExternal = async () => { throw new Error('fixture failure'); }; });
  await page.getByRole('button', { name: '前往设置', exact: true }).click();
  await page.getByRole('alert').filter({ hasText: '无法打开系统设置，请手动前往' }).waitFor();

  console.log('PASS: default trash shortcut, merged volume entries, folder/history navigation, readonly guards, persistent unpin/repin, fixture content preserved.');
} finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
