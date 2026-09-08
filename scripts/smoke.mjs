import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'mac-explorer-ui-'));
const repository = process.cwd();
const artifactPath = path.join(repository, 'artifacts');
await fs.mkdir(artifactPath, { recursive: true });
for (const folder of ['Desktop', 'Downloads', 'Documents', 'Pictures', 'Music', 'Movies']) await fs.mkdir(path.join(root, folder));
const docs = path.join(root, 'Documents');
await fs.mkdir(path.join(docs, '工作项目'));
await fs.mkdir(path.join(docs, '设计素材'));
await fs.writeFile(path.join(docs, '会议记录.md'), '# 项目会议\n\n这是自动化测试创建的临时文件。\n');
await fs.writeFile(path.join(docs, '旅行计划.txt'), 'Tokyo / Shanghai\n');
await fs.writeFile(path.join(docs, '.hidden-test'), 'hidden');
await fs.writeFile(path.join(docs, '工作项目', 'nested-search.txt'), 'nested result');
const errors = [];
let app;
try {
  app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [repository] }), env: { ...process.env, EXPLORER_TEST_ROOT: root }, timeout: 30000 });
  // Keep clipboard payloads in the fixture process only; never log or persist them.
  await app.evaluate(async ({ clipboard, ClipboardItem }) => {
    globalThis.smokeClipboard = await Promise.all((await clipboard.read()).map(async item => new ClipboardItem(Object.fromEntries(await Promise.all(item.types.map(async type => [type, await item.getType(type)]))))));
  });
  const page = await app.firstWindow();
  page.on('pageerror', error => errors.push(error.message));
  await page.getByRole('option', { name: '会议记录.md', exact: true }).waitFor();
  console.log('PASS: native launch and real directory listing');
  assert.equal(await page.getByRole('option').count(), 4);
  const bridge = await page.evaluate(() => ({ node: typeof window.require, bridge: typeof window.explorer?.list }));
  assert.deepEqual(bridge, { node: 'undefined', bridge: 'function' });
  console.log('PASS: context-isolated renderer');
  await page.screenshot({ path: path.join(artifactPath, 'details-test-fixture.png') });

  await page.getByRole('option', { name: '会议记录.md', exact: true }).click();
  await page.keyboard.press('Control+c');
  await page.waitForFunction(() => document.querySelector('.status-feedback')?.textContent.includes('已复制'));
  const clip = await page.evaluate(() => window.explorer.clipboardGet());
  assert.deepEqual(clip.paths, [path.join(docs, '会议记录.md')]);
  await page.keyboard.press('Control+v');
  await page.getByRole('option', { name: '会议记录 - 副本.md', exact: true }).waitFor();
  assert.equal(await fs.readFile(path.join(docs, '会议记录 - 副本.md'), 'utf8'), await fs.readFile(path.join(docs, '会议记录.md'), 'utf8'));
  console.log('PASS: Ctrl+C / Ctrl+V and collision-safe duplicate naming');

  await page.keyboard.press('Control+z');
  await page.getByRole('option', { name: '会议记录 - 副本.md', exact: true }).waitFor({ state: 'detached' });
  await assert.rejects(fs.access(path.join(docs, '会议记录 - 副本.md')));
  await page.getByRole('option', { name: '会议记录.md', exact: true }).click();
  await page.keyboard.press('Meta+c');
  await page.waitForFunction(() => document.querySelector('.status-feedback')?.textContent.includes('已复制'));
  await page.keyboard.press('Meta+v');
  await page.getByRole('option', { name: '会议记录 - 副本.md', exact: true }).waitFor();
  console.log('PASS: Ctrl+Z safely undoes a copy; Command shortcuts reach file operations');

  await page.getByRole('option', { name: '会议记录 - 副本.md', exact: true }).click();
  await page.keyboard.press('F2');
  await page.getByLabel('名称', { exact: true }).fill('已重命名.md');
  await page.getByLabel('名称', { exact: true }).press('Enter');
  await page.getByRole('option', { name: '已重命名.md', exact: true }).waitFor();
  console.log('PASS: F2 rename updates disk and UI');

  await page.keyboard.press('Control+Shift+n');
  await page.getByLabel('名称', { exact: true }).fill('测试新文件夹');
  await page.getByLabel('名称', { exact: true }).press('Enter');
  await page.getByRole('option', { name: '测试新文件夹', exact: true }).waitFor();
  assert.equal((await fs.stat(path.join(docs, '测试新文件夹'))).isDirectory(), true);
  console.log('PASS: Ctrl+Shift+N creates a real folder');

  await page.getByRole('option', { name: '已重命名.md', exact: true }).click();
  await page.keyboard.press('Control+x');
  await page.waitForFunction(() => document.querySelector('.status-feedback')?.textContent.includes('已剪切'));
  await page.getByRole('option', { name: '测试新文件夹', exact: true }).dblclick();
  await page.getByText('此文件夹为空', { exact: true }).waitFor();
  await page.keyboard.press('Control+v');
  await page.getByRole('option', { name: '已重命名.md', exact: true }).waitFor();
  await assert.rejects(fs.access(path.join(docs, '已重命名.md')));
  await fs.access(path.join(docs, '测试新文件夹', '已重命名.md'));
  await page.keyboard.press('Alt+ArrowLeft');
  await page.getByRole('option', { name: '会议记录.md', exact: true }).waitFor();
  console.log('PASS: cut/paste moves the original; Alt+Left restores previous folder');

  await page.getByRole('button', { name: '查看', exact: true }).click();
  await page.getByRole('menuitem', { name: '显示', exact: true }).hover();
  await page.getByRole('menuitemcheckbox', { name: '隐藏的项目', exact: true }).click();
  await page.getByRole('option', { name: '.hidden-test', exact: true }).waitFor();
  console.log('PASS: hidden files toggle');
  await page.getByRole('button', { name: '大图标视图', exact: true }).click();
  await page.locator('.icon-grid').waitFor();
  await page.screenshot({ path: path.join(artifactPath, 'icons-test-fixture.png') });
  await page.getByRole('button', { name: '详细信息视图', exact: true }).click();
  await page.getByRole('option', { name: '会议记录.md', exact: true }).click();
  await page.getByRole('button', { name: '查看', exact: true }).click();
  await page.getByRole('menuitemcheckbox', { name: '详细信息窗格', exact: true }).click();
  await page.locator('.text-preview pre').waitFor();
  assert.match(await page.locator('.text-preview pre').innerText(), /项目会议/);
  console.log('PASS: icon/details views and real text preview');
  await page.getByRole('button', { name: '关闭详细信息', exact: true }).click();

  await page.getByRole('textbox', { name: '搜索文件', exact: true }).fill('nested-search');
  await page.getByRole('textbox', { name: '搜索文件', exact: true }).press('Enter');
  await page.getByRole('option', { name: 'nested-search.txt', exact: true }).waitFor();
  assert.equal(await page.getByRole('option').count(), 1);
  await page.getByRole('button', { name: '退出搜索', exact: true }).click();
  await page.getByRole('option', { name: '会议记录.md', exact: true }).waitFor();
  console.log('PASS: recursive search returns nested real files');

  await page.getByRole('option', { name: '会议记录.md', exact: true }).click({ button: 'right' });
  await page.getByRole('menuitem', { name: '复制文件地址', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.status-feedback')?.textContent === '已复制文件地址');
  console.log('PASS: context menu file action');

  await page.keyboard.press('Control+t');
  await page.locator('.home-content').waitFor();
  assert.equal(await page.getByRole('tab').count(), 2);
  await page.screenshot({ path: path.join(artifactPath, 'home-test-fixture.png') });
  await page.keyboard.press('Control+w');
  assert.equal(await page.getByRole('tab').count(), 1);
  await page.getByRole('option', { name: '会议记录.md', exact: true }).waitFor();
  console.log('PASS: new/close tabs preserve the prior location');
  await page.keyboard.press('Meta+t');
  await page.locator('.home-content').waitFor();
  await page.keyboard.press('Meta+w');
  await page.getByRole('option', { name: '会议记录.md', exact: true }).waitFor();
  assert.equal(await page.getByRole('tab').count(), 1);
  await page.getByRole('button', { name: '展开 文档', exact: true }).click();
  await page.getByRole('group', { name: '文档 的子文件夹', exact: true }).getByRole('button', { name: '工作项目', exact: true }).click();
  await page.getByRole('option', { name: 'nested-search.txt', exact: true }).waitFor();
  console.log('PASS: Command tab shortcuts and expandable native directory tree');

  await page.keyboard.press('Control+l');
  await page.getByRole('textbox', { name: '文件夹地址', exact: true }).fill(path.join(root, 'Downloads'));
  await page.getByRole('textbox', { name: '文件夹地址', exact: true }).press('Enter');
  await page.getByText('此文件夹为空', { exact: true }).waitFor();
  const dropped = path.join(root, 'Downloads', '外部新增.txt');
  await fs.writeFile(dropped, 'watch');
  await page.getByRole('option', { name: '外部新增.txt', exact: true }).waitFor();
  console.log('PASS: address navigation and live external filesystem changes');

  await page.getByRole('option', { name: '外部新增.txt', exact: true }).click();
  await page.keyboard.press('Delete');
  await page.getByRole('button', { name: '移到废纸篓', exact: true }).click();
  await page.getByText('此文件夹为空', { exact: true }).waitFor();
  await assert.rejects(fs.access(dropped));
  console.log('PASS: Delete moves a temporary test file to native Trash');

  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(820, 600));
  await page.screenshot({ path: path.join(artifactPath, 'compact-test-fixture.png') });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
  assert.equal(overflow, false);
  assert.deepEqual(errors, []);
  console.log('PASS: compact desktop layout; no renderer exceptions');
  await fs.writeFile(path.join(artifactPath, process.env.EXPLORER_APP_PATH ? 'packaged-smoke-result.json' : 'smoke-result.json'), JSON.stringify({ passed: true, executable: process.env.EXPLORER_APP_PATH || 'development Electron', rendererErrors: errors, testedAt: new Date().toISOString(), fixture: 'temporary real filesystem files', platform: process.platform, architecture: process.arch }, null, 2));
} catch (error) {
  if (app) { const page = await app.firstWindow(); await page.screenshot({ path: path.join(artifactPath, 'failure.png') }).catch(() => {}); console.error(await page.locator('body').innerText().catch(() => '')); }
  throw error;
} finally {
  if (app) await app.evaluate(async ({ clipboard }, fixtureRoot) => {
    const current = await clipboard.readText();
    // Do not replace anything the user copied while the fixture was running.
    if (current.includes(fixtureRoot) || current.includes(encodeURI(fixtureRoot))) {
      if (globalThis.smokeClipboard?.length) await clipboard.write(globalThis.smokeClipboard);
      else clipboard.clear();
    }
    delete globalThis.smokeClipboard;
  }, root).catch(() => {});
  await app?.close();
  await fs.rm(root, { recursive: true, force: true });
}
