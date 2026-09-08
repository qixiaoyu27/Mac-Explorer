import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-view-'));
const docs = path.join(root, 'Documents');
await fs.mkdir(docs);
await fs.mkdir(path.join(docs, '文件夹'));
await fs.writeFile(path.join(docs, '预览.txt'), 'View menu fixture\n中文内容预览');
await fs.writeFile(path.join(docs, '.hidden-test'), 'hidden');
await fs.writeFile(path.join(docs, 'image.png'), Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=', 'base64'));
for (let i = 0; i < 45; i++) await fs.writeFile(path.join(docs, `文件 ${String(i).padStart(2, '0')}.txt`), `Fixture ${i}`);
await fs.mkdir('artifacts', { recursive: true });
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
const page = await app.firstWindow();
const errors = []; page.on('pageerror', error => errors.push(error.message));
const viewButton = page.getByRole('button', { name: '查看', exact: true });
const choose = async (name, role = 'menuitemradio') => { await viewButton.click(); await page.getByRole(role, { name, exact: true }).click(); };
const show = async name => { await viewButton.click(); await page.getByRole('menuitem', { name: '显示', exact: true }).hover(); await page.getByRole('menuitemcheckbox', { name, exact: true }).click(); };
try {
  await page.getByRole('option', { name: '预览.txt', exact: true }).waitFor();
  await viewButton.click();
  assert.deepEqual(await page.locator('.context-menu > div > button').evaluateAll(items => items.map(item => item.textContent.trim())), ['超大图标', '大图标', '中图标', '小图标', '列表', '详细信息', '平铺', '内容', '详细信息窗格', '预览窗格', '显示']);
  await page.keyboard.press('End'); await page.keyboard.press('ArrowRight');
  await page.getByRole('menu', { name: '显示', exact: true }).waitFor();
  await page.waitForFunction(() => document.activeElement?.textContent.trim() === '导航窗格');
  assert.deepEqual(await page.locator('.context-submenu button').evaluateAll(items => items.map(item => item.textContent.trim())), ['导航窗格', '紧凑视图', '项目复选框', '文件扩展名', '隐藏的项目']);
  await page.keyboard.press('ArrowLeft');
  assert.equal(await page.locator('.context-submenu').count(), 0);
  assert.equal(await page.evaluate(() => document.activeElement.textContent.trim()), '显示');
  await page.keyboard.press('Escape');
  console.log('PASS: exact menu order, nested Show menu and keyboard return');

  for (const [name, cls] of [['超大图标', 'icon-grid'], ['大图标', 'icon-grid'], ['中图标', 'icon-grid'], ['小图标', 'small-icons'], ['列表', 'file-list'], ['详细信息', 'file-table'], ['平铺', 'file-tiles'], ['内容', 'file-content-view']]) {
    await choose(name);
    await page.locator(`.file-items.${cls}`).waitFor();
    if (name === '列表') {
      const boxes = await page.locator('.file-row').evaluateAll(rows => rows.map(row => { const r = row.getBoundingClientRect(); return { x: r.x, y: r.y }; }));
      assert.equal(boxes[0].x, boxes[1].x); assert.ok(boxes[1].y > boxes[0].y); assert.ok(boxes.some(b => b.x > boxes[0].x));
    }
    if (name === '平铺') assert.match(await page.getByRole('option', { name: '预览.txt', exact: true }).innerText(), /文本文档/);
    if (name === '内容') assert.match(await page.getByRole('option', { name: '预览.txt', exact: true }).innerText(), /修改日期/);
    await viewButton.click();
    assert.equal(await page.getByRole('menuitemradio', { name, exact: true }).getAttribute('aria-checked'), 'true');
    assert.equal(await page.locator('[role=menuitemradio][aria-checked=true]').count(), 1);
    await page.keyboard.press('Escape');
  }
  console.log('PASS: eight functional layouts and exclusive view selection');

  await choose('详细信息');
  const rowHeight = await page.locator('.file-row').first().evaluate(el => el.getBoundingClientRect().height);
  await show('紧凑视图');
  assert.ok(await page.locator('.file-row').first().evaluate(el => el.getBoundingClientRect().height) < rowHeight);
  await show('导航窗格'); assert.equal(await page.locator('.sidebar').count(), 0);
  await show('项目复选框');
  for (const mode of ['大图标', '详细信息']) {
    await choose(mode);
    const row = page.getByRole('option', { name: '文件夹', exact: true });
    const checkbox = row.getByRole('checkbox');
    await viewButton.focus(); await page.mouse.move(5, 5);
    assert.equal(await checkbox.evaluate(el => getComputedStyle(el).opacity), '0');
    await row.hover();
    assert.equal(await checkbox.evaluate(el => getComputedStyle(el).opacity), '1');
    await checkbox.check(); await viewButton.focus(); await page.mouse.move(5, 5);
    assert.equal(await checkbox.evaluate(el => getComputedStyle(el).opacity), '1');
    await row.hover(); await checkbox.uncheck(); await viewButton.focus(); await page.mouse.move(5, 5);
    assert.equal(await checkbox.evaluate(el => getComputedStyle(el).opacity), '0');
    await page.keyboard.press('Tab'); await checkbox.focus();
    assert.equal(await checkbox.evaluate(el => getComputedStyle(el).opacity), '1');
  }
  console.log('PASS: checkbox hover, selected persistence, leave/uncheck hiding and keyboard focus in icon/detail views');
  await page.getByRole('checkbox', { name: '选择 预览.txt', exact: true }).check();
  await page.getByRole('checkbox', { name: '选择 image.png', exact: true }).check();
  assert.equal(await page.locator('.file-row[aria-selected=true]').count(), 2);
  assert.equal(await page.getByRole('checkbox', { name: '全选文件' }).evaluate(el => el.indeterminate), true);
  await page.getByRole('checkbox', { name: '选择 预览.txt', exact: true }).uncheck();
  assert.equal(await page.locator('.file-row[aria-selected=true]').count(), 1);
  await page.getByRole('checkbox', { name: '全选文件' }).check(); assert.equal(await page.locator('.file-row[aria-selected=true]').count(), 48);
  await page.getByRole('checkbox', { name: '全选文件' }).uncheck();
  await show('文件扩展名');
  assert.equal(await page.getByRole('option', { name: '预览.txt', exact: true }).locator('.entry-name').innerText(), '预览');
  await show('隐藏的项目'); await page.getByRole('option', { name: '.hidden-test', exact: true }).waitFor();
  console.log('PASS: compact spacing, navigation, checkbox multi-select, extensions and hidden files');

  await choose('预览窗格', 'menuitemcheckbox');
  await page.getByText('选择要预览的文件。', { exact: true }).waitFor();
  await page.getByRole('option', { name: '预览.txt', exact: true }).click();
  await page.locator('.preview-pane pre').waitFor(); assert.match(await page.locator('.preview-pane pre').innerText(), /中文内容预览/);
  await page.getByRole('option', { name: 'image.png', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.pane-image-preview')?.naturalWidth === 1);
  await page.getByRole('option', { name: '文件夹', exact: true }).click(); await page.getByText('文件夹不提供内容预览。').waitFor();
  await choose('详细信息窗格', 'menuitemcheckbox');
  assert.equal(await page.locator('.preview-pane').count(), 0); await page.locator('.details-pane dl').waitFor();
  await page.getByRole('button', { name: '预览窗格', exact: true }).click();
  assert.equal(await page.locator('.details-pane').count(), 1); await page.locator('.preview-pane').waitFor();
  await page.getByRole('option', { name: '预览.txt', exact: true }).click();
  console.log('PASS: real text/image previews, empty/folder states and exclusive panes');

  await choose('平铺');
  await page.reload(); await page.getByRole('option', { name: '预览.txt', exact: true }).waitFor();
  await page.locator('.file-tiles.with-checkboxes').waitFor();
  assert.equal(await page.locator('.sidebar').count(), 0);
  await page.locator('.compact-view').waitFor(); await page.locator('.preview-pane').waitFor();
  await page.getByRole('option', { name: '.hidden-test', exact: true }).waitFor();
  assert.equal(await page.getByRole('option', { name: '预览.txt', exact: true }).locator('.entry-name').evaluate(el => el.firstChild.textContent), '预览');
  await show('导航窗格');
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(820, 600));
  await viewButton.click(); await page.getByRole('menuitem', { name: '显示', exact: true }).hover();
  assert.equal(await page.locator('.context-menu').evaluateAll(menus => menus.every(menu => { const r = menu.getBoundingClientRect(); return r.left >= 0 && r.top >= 0 && r.right <= innerWidth && r.bottom <= innerHeight; })), true);
  await page.screenshot({ path: 'artifacts/view-menu-compact.png' });
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  await choose('内容');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await page.screenshot({ path: 'artifacts/content-view-compact.png' });
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1280, 820));
  await choose('详细信息'); await viewButton.click(); await page.getByRole('menuitem', { name: '显示', exact: true }).hover();
  await page.screenshot({ path: 'artifacts/view-menu-reference.png' });
  assert.deepEqual(errors, []);
  console.log('PASS: persisted settings, viewport-safe submenus, compact layout and no renderer errors');
  await fs.writeFile(`artifacts/${process.env.EXPLORER_APP_PATH ? 'packaged-' : ''}view-menu-result.json`, JSON.stringify({ passed: true, executable: process.env.EXPLORER_APP_PATH || 'source build', testedAt: new Date().toISOString(), errors }, null, 2));
} catch (error) { await page.screenshot({ path: 'artifacts/view-menu-failure.png' }); throw error; }
finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
