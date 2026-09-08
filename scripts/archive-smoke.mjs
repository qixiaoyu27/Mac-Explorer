import { _electron as electron } from 'playwright';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-archive-'));
const docs = path.join(root, 'Documents');
await fs.mkdir(docs);
const zip = path.join(docs, '资料 $(test) 中文-agentgo-gift-k8s-100-ows-ingress-20260908.zip');
execFileSync('/usr/bin/python3', ['-c', `import zipfile,sys,tarfile,io
with zipfile.ZipFile(sys.argv[1], 'w') as z:
 z.writestr('说明.txt', 'test content')
 z.writestr('项目/子目录/内容.txt', 'nested')
 z.writestr('空文件夹/', '')
with zipfile.ZipFile(sys.argv[2], 'w'): pass
with tarfile.open(sys.argv[3], 'w:gz') as t:
 data=b'test'; item=tarfile.TarInfo('中文文件.txt'); item.size=len(data); t.addfile(item,io.BytesIO(data))
`, zip, path.join(docs, '空.zip'), path.join(docs, '资料.tar.gz')]);
await fs.writeFile(path.join(docs, '损坏.zip'), 'not an archive');
await fs.writeFile(path.join(docs, '普通.txt'), 'normal');
const before = await fs.readdir(docs);
const original = await fs.readFile(zip);
let app;
let temporaryOpens = [];
try {
 app = await electron.launch({ colorScheme: null, ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
 const page = await app.firstWindow();
 const errors = []; page.on('pageerror', e => errors.push(e.message));
 // Trap external launches in the fixture process, so a regression cannot extract files.
 await app.evaluate(({ shell }) => { globalThis.externalOpens = []; shell.openPath = async p => { globalThis.externalOpens.push(p); return ''; }; });
 const entry = page.getByRole('option', { name: path.basename(zip), exact: true });
 await entry.waitFor(); await entry.dblclick();
 const dialog = page.getByRole('dialog', { name: path.basename(zip), exact: true });
 await dialog.waitFor();
 assert.deepEqual(await dialog.getByRole('combobox', { name: '解压位置' }).locator('option').allTextContents(), ['指定路径', '当前路径', path.basename(zip, '.zip')]);
 await dialog.getByRole('button', { name: '项目 文件夹', exact: true }).dblclick();
 await dialog.getByRole('button', { name: '子目录 文件夹', exact: true }).focus(); await page.keyboard.press('Enter');
 await dialog.getByRole('button', { name: '内容.txt', exact: true }).focus();
 await page.keyboard.press('Enter');
 await page.waitForFunction(() => document.querySelector('.archive-result')?.textContent.includes('已用默认应用打开'));
 temporaryOpens = await app.evaluate(() => globalThis.externalOpens);
 assert.equal(temporaryOpens.length, 1);
 assert.equal(await fs.readFile(temporaryOpens[0], 'utf8'), 'nested');
 assert(temporaryOpens[0].endsWith('/项目/子目录/内容.txt'));
 await fs.writeFile(temporaryOpens[0], 'edited temporary copy');
 await dialog.getByRole('button', { name: '压缩包内向上一级', exact: true }).click();
 await dialog.getByRole('button', { name: '子目录 文件夹', exact: true }).waitFor();
 await dialog.getByRole('button', { name: '压缩包内向上一级', exact: true }).click();
 execFileSync('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0081;65000000;Mac Explorer Test;', zip]);
 await dialog.getByRole('button', { name: '说明.txt', exact: true }).dblclick();
 await page.waitForFunction(() => document.querySelector('.archive-result')?.textContent.includes('已用默认应用打开'));
 temporaryOpens = await app.evaluate(() => globalThis.externalOpens);
 assert.equal(temporaryOpens.length, 2);
 assert.equal(await fs.readFile(temporaryOpens[1], 'utf8'), 'test content');
 assert.equal(execFileSync('/usr/bin/xattr', ['-p', 'com.apple.quarantine', temporaryOpens[1]], { encoding: 'utf8' }).trim(), '0081;65000000;Mac Explorer Test;');
 await assert.rejects(() => page.evaluate(zip => window.explorer.openArchiveFile(zip, '../outside.txt'), zip), /请选择/);
 await assert.rejects(() => page.evaluate(zip => window.explorer.openArchiveFile(zip, '项目'), zip), /请选择/);
 await app.evaluate(({ shell }) => { shell.openPath = async p => { globalThis.failedOpen = p; return '测试：没有默认应用'; }; });
 await dialog.getByRole('button', { name: '说明.txt', exact: true }).dblclick();
 await dialog.getByRole('alert').waitFor();
 assert.match(await dialog.getByRole('alert').innerText(), /没有默认应用/);
 const failedOpen = await app.evaluate(() => globalThis.failedOpen);
 assert.equal(await fs.stat(failedOpen).then(() => true, () => false), false);
 await app.evaluate(({ shell }) => { globalThis.externalOpens = []; shell.openPath = async p => { globalThis.externalOpens.push(p); return ''; }; });
 await fs.mkdir('artifacts', { recursive: true });
 await page.screenshot({ path: 'artifacts/archive-preview.png' });
 await page.keyboard.press('Escape');
 await entry.click(); await page.keyboard.press('Enter'); await dialog.waitFor(); await page.keyboard.press('Escape');
 await entry.click({ button: 'right' }); await page.getByRole('menuitem', { name: '打开', exact: true }).click(); await dialog.waitFor(); await page.keyboard.press('Escape');
 await page.keyboard.press('Control+l');
 await page.getByRole('textbox', { name: '文件夹地址', exact: true }).fill(zip);
 await page.getByRole('textbox', { name: '文件夹地址', exact: true }).press('Enter'); await dialog.waitFor(); await page.keyboard.press('Escape');
 assert.equal(await app.evaluate(() => globalThis.externalOpens.length), 0);
 console.log('PASS: double-click, Enter, context Open and address all preview ZIP; nested folders and literal special paths');
 await page.getByRole('option', { name: '资料.tar.gz', exact: true }).dblclick();
 await page.getByRole('dialog').getByRole('button', { name: '中文文件.txt', exact: true }).waitFor(); await page.keyboard.press('Escape');
 await page.getByRole('option', { name: '空.zip', exact: true }).dblclick(); await page.getByText('此压缩包为空', { exact: true }).waitFor(); await page.keyboard.press('Escape');
 await page.getByRole('option', { name: '损坏.zip', exact: true }).dblclick(); await page.getByRole('alert').waitFor();
 assert.match(await page.getByRole('alert').innerText(), /无法预览此压缩包/);
 assert.equal(await app.evaluate(() => globalThis.externalOpens.length), 0);
 await page.getByRole('option', { name: '普通.txt', exact: true }).dblclick();
 await page.waitForFunction(() => !document.querySelector('.status-feedback')?.textContent.includes('正在打开'));
 assert.deepEqual(await app.evaluate(() => globalThis.externalOpens), [path.join(docs, '普通.txt')]);
 assert.deepEqual(await fs.readdir(docs), before); assert.deepEqual(await fs.readFile(zip), original);
 await page.evaluate(() => window.explorer.setTheme('dark')); await entry.dblclick(); await dialog.waitFor();
 await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(820, 600));
 await dialog.getByRole('combobox', { name: '解压位置' }).selectOption('folder');
 await page.screenshot({ path: 'artifacts/archive-preview-dark.png' });
 assert.equal(await dialog.locator('.archive-actions').evaluate(el => el.scrollWidth <= el.clientWidth), true);
 assert.equal(await dialog.evaluate(el => { const r = el.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth && r.bottom <= innerHeight; }), true);
 assert.equal(await fs.readFile(temporaryOpens[0], 'utf8'), 'edited temporary copy');
 assert.deepEqual(await fs.readFile(zip), original);
 assert.deepEqual(errors, []);
 console.log('PASS: archive file double-click/Enter, correct isolated content, quarantine inheritance, invalid selections, failed launch cleanup, temporary edits preserved, labels');
 console.log('PASS: TAR.GZ, empty ZIP, corrupt error without fallback, normal-file routing, no adjacent extraction or archive changes, compact dark dialog');
} finally {
 await app?.close();
 for (const file of temporaryOpens) {
   const relative = path.relative(os.tmpdir(), file).split(path.sep)[0];
   assert(relative.startsWith('mac-explorer-open-'));
   await fs.rm(path.join(os.tmpdir(), relative), { recursive: true, force: true });
 }
 await fs.rm(root, { recursive: true, force: true });
}
