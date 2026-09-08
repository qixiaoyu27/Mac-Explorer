import { _electron as electron } from 'playwright';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-extract-test-'));
const docs = path.join(root, 'Documents');
const output = path.join(root, '指定目录 $(test)');
await fs.mkdir(docs); await fs.mkdir(output);
const zip = path.join(docs, '资料 $(test).zip');
execFileSync('/usr/bin/python3', ['-c', `import zipfile,tarfile,io,sys,os,stat
root,docs,archive=sys.argv[1:]
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as z:
 z.writestr('说明.txt','plain')
 z.writestr('项目/子目录/内容.txt','nested')
 z.writestr('特殊[*]?\\n中文.txt','literal')
 z.writestr('空文件夹/','')
for name,member in [('traversal','../escaped.txt'),('absolute',root+'/escaped.txt'),('windows','C:\\\\escaped.txt')]:
 with zipfile.ZipFile(docs+'/'+name+'.zip','w') as z: z.writestr(member,'unsafe')
for name,typ in [('symlink',tarfile.SYMTYPE),('hardlink',tarfile.LNKTYPE)]:
 with tarfile.open(docs+'/'+name+'.tar','w') as t:
  e=tarfile.TarInfo('link'); e.type=typ; e.linkname=root; t.addfile(e)
with zipfile.ZipFile(docs+'/duplicate.zip','w') as z:
 z.writestr('a.txt','one');z.writestr('./a.txt','two')
with zipfile.ZipFile(docs+'/crc.zip','w',compression=zipfile.ZIP_STORED) as z: z.writestr('bad.txt','UNIQUEPAYLOAD')
p=docs+'/crc.zip';data=open(p,'rb').read().replace(b'UNIQUEPAYLOAD',b'BROKENPAYLOAD');open(p,'wb').write(data)
`, root, docs, zip]);
const original = await fs.readFile(zip);
let app;
try {
  app = await electron.launch({ colorScheme: null, ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
  const page = await app.firstWindow();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.getByRole('option', { name: path.basename(zip), exact: true }).waitFor();
  await app.evaluate(({ dialog, shell }, out) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [out] });
    shell.openPath = async () => { throw new Error('Archive must not open externally'); };
  }, output);
  const extract = (file, selected = null, mode = 'choose') => page.evaluate(async ({ file, selected, mode }) => window.explorer.extractArchive(file, selected, mode), { file, selected, mode });
  const entry = page.getByRole('option', { name: path.basename(zip), exact: true });
  await entry.dblclick();
  const dialog = page.getByRole('dialog');
  await dialog.getByRole('checkbox', { name: '选择 说明.txt', exact: true }).check();
  await dialog.getByRole('checkbox', { name: '选择 项目', exact: true }).check();
  await dialog.getByRole('button', { name: '解压选中项', exact: true }).click();
  await dialog.getByRole('status').waitFor();
  assert.equal(await fs.readFile(path.join(output, '说明.txt'), 'utf8'), 'plain');
  assert.equal(await fs.readFile(path.join(output, '项目/子目录/内容.txt'), 'utf8'), 'nested');
  assert.deepEqual((await fs.readdir(output)).sort(), ['说明.txt', '项目'].sort());
  await dialog.getByRole('checkbox', { name: '全选当前目录', exact: true }).check();
  assert.equal(await dialog.locator('.archive-entry input:checked').count(), 4);
  await dialog.getByRole('checkbox', { name: '全选当前目录', exact: true }).uncheck();
  await page.keyboard.press('Meta+a');
  assert.equal(await dialog.locator('.archive-entry input:checked').count(), 4);
  await dialog.getByRole('button', { name: '项目 文件夹', exact: true }).dblclick();
  await dialog.getByRole('checkbox', { name: '选择 子目录', exact: true }).check();
  await dialog.getByRole('combobox', { name: '解压位置' }).selectOption('folder');
  await dialog.getByRole('button', { name: '解压选中项', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.archive-result')?.textContent.includes('已解压到'));
  assert.equal(await fs.readFile(path.join(docs, '资料 $(test)/项目/子目录/内容.txt'), 'utf8'), 'nested');
  await fs.mkdir('artifacts', { recursive: true });
  await page.screenshot({ path: 'artifacts/archive-extract.png' });
  await page.keyboard.press('Escape');
  // Collision does not replace a file or merge a directory, including symlinks.
  await fs.writeFile(path.join(output, '说明.txt'), 'keep');
  const all = await extract(zip);
  assert.equal(all.errors.length, 2); assert.equal(all.succeeded.length, 2);
  assert.equal(await fs.readFile(path.join(output, '说明.txt'), 'utf8'), 'keep');
  assert.equal(await fs.readFile(path.join(output, '特殊[*]?\n中文.txt'), 'utf8'), 'literal');
  const collision = await extract(zip, null, 'folder'); assert.equal(collision.errors.length, 1);
  assert.deepEqual(await fs.readdir(path.join(docs, '资料 $(test)')), ['项目']);
  // Context extraction here and named-folder routes run the actual IPC and native helper.
  await entry.click({ button: 'right' }); await page.getByRole('menuitem', { name: '解压到当前目录', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('.status-feedback')?.textContent.includes('正在解压'));
  assert.equal(await fs.readFile(path.join(docs, '说明.txt'), 'utf8'), 'plain');
  const second = path.join(docs, '第二份.zip'); await fs.copyFile(zip, second);
  await page.keyboard.press('F5');
  await page.getByRole('option', { name: '第二份.zip', exact: true }).click({ button: 'right' });
  await page.getByRole('menuitem', { name: '解压到“第二份/”', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('.status-feedback')?.textContent.includes('正在解压'));
  assert.equal(await fs.readFile(path.join(docs, '第二份/说明.txt'), 'utf8'), 'plain');
  const linkTarget = path.join(root, 'link-target'); await fs.mkdir(linkTarget);
  const securityOutput = path.join(root, 'security'); await fs.mkdir(securityOutput);
  await fs.symlink(linkTarget, path.join(securityOutput, '项目'));
  await app.evaluate(({ dialog }, out) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [out] }); }, securityOutput);
  const linked = await extract(zip, ['项目']); assert.equal(linked.errors.length, 1); assert.deepEqual(await fs.readdir(linkTarget), []);
  await fs.unlink(path.join(securityOutput, '项目'));
  for (const name of ['traversal.zip', 'absolute.zip', 'windows.zip', 'symlink.tar', 'hardlink.tar', 'duplicate.zip', 'crc.zip']) {
    await assert.rejects(() => extract(path.join(docs, name)), /压缩包|解压|包内/);
    assert.deepEqual(await fs.readdir(securityOutput), [], name + ' must leave no output or staging');
  }
  assert.equal(await fs.stat(path.join(root, 'escaped.txt')).then(() => true, () => false), false);
  await assert.rejects(() => extract(zip, []), /无效/);
  await assert.rejects(() => extract(zip, ['../escaped']), /无效/);
  await app.evaluate(({ dialog }) => { dialog.showOpenDialog = async () => ({ canceled: true, filePaths: [] }); });
  assert.equal(await extract(zip), null); assert.deepEqual(await fs.readdir(securityOutput), []);
  await app.evaluate(({ dialog }, out) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [out] }); }, securityOutput);
  for (const [name, args] of [['native.tar.gz', ['-czf']], ['native.7z', ['--format', '7zip', '-cf']]]) {
    const archivePath = path.join(docs, name);
    execFileSync('/usr/bin/tar', [...args, archivePath, '-C', output, '说明.txt']);
    const result = await extract(archivePath); assert.equal(result.errors.length, 0);
    assert.equal(await fs.readFile(path.join(securityOutput, '说明.txt'), 'utf8'), 'keep');
    await fs.unlink(path.join(securityOutput, '说明.txt'));
  }
  assert.deepEqual(await fs.readFile(zip), original);
  await entry.dblclick(); await page.evaluate(() => window.explorer.setTheme('dark'));
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(820, 600));
  await page.waitForFunction(() => matchMedia('(prefers-color-scheme: dark)').matches);
  await page.screenshot({ path: 'artifacts/archive-extract-dark.png' });
  assert.equal(await dialog.locator('.archive-list').evaluate(el => el.scrollWidth <= el.clientWidth), true);
  assert.equal(await dialog.locator('input[type=checkbox]').first().evaluate(el => el.getBoundingClientRect().width), 16);
  assert.equal(await dialog.evaluate(el => { const r = el.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth && r.bottom <= innerHeight; }), true);
  assert.deepEqual(errors, []);
  console.log('PASS: selected files/folders, nested selection, select-all, exact Unicode/control/glob names, all extraction, three destinations, context routes, collision/symlink preservation, malicious paths/links/CRC/duplicates, cancellation, unchanged archive, dark compact UI');
} finally { await app?.close(); await fs.rm(root, { recursive: true, force: true }); }
