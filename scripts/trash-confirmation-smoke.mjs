import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-trash-confirmation-'));
await fs.mkdir(path.join(root, 'Documents'));
await fs.writeFile(path.join(root, 'Documents', 'example.txt'), 'Preserve this fixture');
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  // Test the confirmation contract without sending any file to the real Trash.
  await app.evaluate(({ ipcMain }) => {
    globalThis.trashCalls = [];
    globalThis.failTrash = false;
    ipcMain.removeHandler('trash');
    ipcMain.handle('trash', (_event, paths) => {
      if (globalThis.failTrash) throw new Error('Test failure');
      globalThis.trashCalls.push(paths);
      return { succeeded: paths, errors: [] };
    });
  });
  const page = await app.firstWindow();
  const select = async () => {
    await page.locator('.file-content[aria-busy=false]').waitFor();
    await page.getByRole('option', { name: 'example.txt', exact: true }).click();
  };
  const open = async () => { await select(); await page.getByRole('button', { name: '移到回收站 (⌘⌫)', exact: true }).click(); };
  const dialog = page.getByRole('dialog');
  const preference = page.getByRole('checkbox', { name: '不再显示此提示' });
  await open(); await preference.check();
  await dialog.getByRole('button', { name: '取消', exact: true }).click();
  assert.equal(await page.evaluate(() => localStorage.getItem('skipTrashConfirmation')), null);
  assert.equal(await app.evaluate(() => globalThis.trashCalls.length), 0);
  await open(); assert.equal(await preference.isChecked(), false);
  await preference.check();
  await app.evaluate(() => { globalThis.failTrash = true; });
  await dialog.getByRole('button', { name: '移到回收站', exact: true }).click();
  await page.locator('.modal-error').waitFor();
  assert.equal(await page.evaluate(() => localStorage.getItem('skipTrashConfirmation')), null);
  await app.evaluate(() => { globalThis.failTrash = false; });
  await page.screenshot({ path: 'artifacts/trash-confirmation-fixture.png' });
  await dialog.getByRole('button', { name: '移到回收站', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  assert.equal(await page.evaluate(() => localStorage.getItem('skipTrashConfirmation')), 'true');
  await page.reload(); await select();
  await page.keyboard.press('Meta+Backspace');
  await page.waitForFunction(() => document.querySelector('.status-feedback')?.textContent.includes('已移到回收站'));
  assert.equal(await dialog.count(), 0);
  assert.equal(await app.evaluate(() => globalThis.trashCalls.length), 2);
  assert.equal(await fs.readFile(path.join(root, 'Documents', 'example.txt'), 'utf8'), 'Preserve this fixture');
  console.log('PASS: cancel does not persist; failure remains retryable; confirm persists; shortcut skips after reload; fixture preserved.');
} finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
