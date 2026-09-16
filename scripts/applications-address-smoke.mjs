import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-apps-address-'));
await fs.mkdir(path.join(root, 'Documents', 'Example.app'), { recursive: true });
await fs.mkdir(path.join(root, 'Applications'));
await fs.writeFile(path.join(root, 'Documents', 'keep.txt'), 'preserved');
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  await app.evaluate(async ({ clipboard, ClipboardItem }) => {
    globalThis.savedClipboard = await Promise.all((await clipboard.read()).map(async item => new ClipboardItem(Object.fromEntries(await Promise.all(item.types.map(async type => [type, await item.getType(type)]))))));
  });
  const page = await app.firstWindow();
  await page.locator('.file-content[aria-busy=false]').waitFor();
  assert.equal(await page.locator('.entry-name', { hasText: 'Example' }).innerText(), 'Example');
  assert.equal(await page.locator('.entry-name', { hasText: 'keep' }).innerText(), 'keep.txt');
  await page.getByRole('button', { name: '编辑地址 (⇧⌘G)', exact: true }).click();
  const input = page.getByRole('textbox', { name: '文件夹地址', exact: true });
  const menu = async label => app.evaluate(async ({ Menu }, label) => {
    const item = Menu.getApplicationMenu().items.find(i => i.label === '编辑').submenu.items.find(i => i.label === label);
    await item.click();
  }, label);
  const destination = path.join(root, 'Applications');
  await app.evaluate(async ({ clipboard }, text) => { await clipboard.writeText(text); }, destination);
  await input.selectText(); await menu('粘贴');
  await page.waitForFunction(text => document.querySelector('[aria-label="文件夹地址"]')?.value === text, destination);
  await input.press('Enter');
  await page.locator('.file-content[aria-label="应用程序"][aria-busy=false]').waitFor();
  await page.getByRole('button', { name: '编辑地址 (⇧⌘G)', exact: true }).click();
  await input.fill('old'); await input.selectText();
  // Exercise the real context-menu handler and its native Paste menu role.
  await app.evaluate(({ Menu, BrowserWindow }) => {
    const original = Menu.prototype.popup;
    Menu.prototype.popup = function () { globalThis.editMenu = this; };
    globalThis.restorePopup = () => { Menu.prototype.popup = original; };
    BrowserWindow.getAllWindows()[0].webContents.emit('context-menu', {}, { isEditable: true, editFlags: { canPaste: true, canCopy: true, canCut: true, canUndo: true } });
  });
  assert.equal(await app.evaluate(() => globalThis.editMenu.items.find(i => i.label === '粘贴').role), 'paste');
  await app.evaluate(({ BrowserWindow }) => { BrowserWindow.getAllWindows()[0].webContents.paste(); globalThis.restorePopup(); });
  await page.waitForFunction(text => document.querySelector('[aria-label="文件夹地址"]')?.value === text, destination);
  assert.ok((await fs.stat(path.join(root, 'Documents', 'Example.app'))).isDirectory());
  console.log('PASS: application display names; Applications label; native menu paste; editable context-menu Paste role; real paths preserved.');
} finally {
  await app.evaluate(async ({ clipboard }) => { if (globalThis.savedClipboard) await clipboard.write(globalThis.savedClipboard); });
  await app.close(); await fs.rm(root, { recursive: true, force: true });
}
