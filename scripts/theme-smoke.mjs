import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-theme-'));
const docs = path.join(root, 'Documents');
for (const folder of ['Documents', 'Downloads', 'Desktop']) await fs.mkdir(path.join(root, folder));
await fs.mkdir(path.join(docs, '工作项目'));
await fs.writeFile(path.join(docs, '使用说明.txt'), '这是外观测试创建的临时文件。\n浅色、深色、跟随系统。');
await fs.writeFile(path.join(docs, '设计资料.pdf'), 'Theme fixture');
await fs.mkdir('artifacts', { recursive: true });
const preference = path.join(root, '.app-data', 'appearance.json');
let app, page;
const errors = [];
const launch = async () => {
  app = await electron.launch({ colorScheme: null, ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root } });
  app.process().on('exit', (code, signal) => console.log(`Fixture process exit: code=${code}, signal=${signal}`));
  page = await app.firstWindow(); page.on('pageerror', error => errors.push(error.message));
  await page.getByRole('option', { name: '使用说明.txt', exact: true }).waitFor();
};
const openAppearance = async () => {
  await page.getByRole('button', { name: '更多', exact: true }).click();
  await page.getByRole('menuitem', { name: '外观', exact: true }).hover();
  await page.getByRole('menu', { name: '外观', exact: true }).waitFor();
};
const choose = async (label, mode) => {
  await openAppearance(); await page.getByRole('menuitemradio', { name: label, exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('.status-feedback')?.textContent.includes('正在切换'));
  assert.equal(await app.evaluate(({ nativeTheme }) => nativeTheme.themeSource), mode);
  assert.equal(JSON.parse(await fs.readFile(preference, 'utf8')).theme, mode);
};
const dark = async value => page.waitForFunction(value => getComputedStyle(document.body).backgroundColor === (value ? 'rgb(25, 25, 25)' : 'rgb(255, 255, 255)'), value);
const bg = selector => page.locator(selector).evaluate(el => getComputedStyle(el).backgroundColor);
const contrast = async (foreground, background) => page.evaluate(({ foreground, background }) => {
  const rgb = value => value.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => { v /= 255; return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; });
  const lum = values => .2126 * values[0] + .7152 * values[1] + .0722 * values[2];
  const f = lum(rgb(getComputedStyle(document.querySelector(foreground)).color));
  const b = lum(rgb(getComputedStyle(document.querySelector(background)).backgroundColor));
  return (Math.max(f, b) + .05) / (Math.min(f, b) + .05);
}, { foreground, background });
try {
  await launch(); await dark(false);
  await openAppearance();
  assert.deepEqual(await page.locator('.context-submenu button').allTextContents(), ['浅色', '深色', '跟随系统']);
  assert.equal(await page.getByRole('menuitemradio', { name: '浅色', exact: true }).getAttribute('aria-checked'), 'true');
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  const previousSettings = await page.evaluate(() => ({ ...localStorage }));
  await choose('深色', 'dark'); await dark(true);
  assert.equal(await app.evaluate(({ nativeTheme }) => nativeTheme.shouldUseDarkColors), true);
  assert.deepEqual(await page.evaluate(() => ({ ...localStorage })), previousSettings);
  assert.equal(await bg('.sidebar'), 'rgb(32, 32, 32)');
  assert.equal(await bg('.address-bar'), 'rgb(44, 44, 44)');
  assert.equal(await bg('.command-bar'), 'rgb(36, 36, 36)');
  assert.equal(await bg('.table-heading'), 'rgb(25, 25, 25)');
  await page.getByRole('option', { name: '使用说明.txt', exact: true }).click();
  assert.ok(await contrast('.entry-name', '.file-row.selected') >= 4.5);
  await page.getByRole('button', { name: '预览窗格', exact: true }).click();
  await page.locator('.preview-pane pre').waitFor();
  assert.ok(await contrast('.preview-pane pre', '.preview-pane') >= 4.5);
  await openAppearance();
  assert.equal(await bg('.context-submenu'), 'rgb(36, 36, 36)');
  assert.equal(await page.getByRole('menuitemradio', { name: '深色', exact: true }).getAttribute('aria-checked'), 'true');
  assert.ok(await contrast('.context-submenu button', '.context-submenu') >= 4.5);
  await page.screenshot({ path: 'artifacts/theme-dark-menu.png' });
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  await page.getByRole('option', { name: '使用说明.txt', exact: true }).click();
  await page.getByRole('button', { name: '移到废纸篓 (Delete)', exact: true }).click();
  await page.getByRole('dialog').waitFor();
  assert.equal(await bg('.modal'), 'rgb(43, 43, 43)');
  assert.ok(await contrast('.trash-description p', '.modal') >= 4.5);
  assert.ok(await contrast('.primary-button', '.primary-button') >= 4.5);
  await page.screenshot({ path: 'artifacts/theme-dark-dialog.png' });
  await page.getByRole('button', { name: '取消', exact: true }).click();
  assert.deepEqual(await fs.readdir(docs), ['使用说明.txt', '工作项目', '设计资料.pdf']);
  console.log('PASS: More > Appearance offers three modes; native dark appearance, all major surfaces and text contrast');

  await app.close(); await launch(); await dark(true);
  assert.equal(await app.evaluate(({ nativeTheme, BrowserWindow }) => ({ source: nativeTheme.themeSource, background: BrowserWindow.getAllWindows()[0].getBackgroundColor() })).then(v => v.source === 'dark' && v.background.toLowerCase() === '#191919'), true);
  await openAppearance(); assert.equal(await page.getByRole('menuitemradio', { name: '深色', exact: true }).getAttribute('aria-checked'), 'true');
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  console.log('PASS: full process restart restores dark mode and native window background');

  await choose('浅色', 'light'); await dark(false);
  assert.equal(await app.evaluate(({ nativeTheme }) => nativeTheme.shouldUseDarkColors), false);
  await openAppearance(); await page.screenshot({ path: 'artifacts/theme-light-menu.png' });
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  await choose('跟随系统', 'system');
  const systemDark = await app.evaluate(({ nativeTheme }) => nativeTheme.shouldUseDarkColors);
  await dark(systemDark);
  // Emulate changes only in this fixture renderer; never change macOS settings.
  await page.emulateMedia({ colorScheme: 'dark' }); await dark(true);
  await page.emulateMedia({ colorScheme: 'light' }); await dark(false);
  assert.equal(await app.evaluate(({ nativeTheme }) => nativeTheme.themeSource), 'system');
  await page.emulateMedia({ colorScheme: null }); await dark(systemDark);
  await app.close(); await launch();
  assert.equal(await app.evaluate(({ nativeTheme }) => nativeTheme.themeSource), 'system');
  await dark(await app.evaluate(({ nativeTheme }) => nativeTheme.shouldUseDarkColors));
  const saved = await fs.readFile(preference, 'utf8');
  assert.equal(await page.evaluate(async () => { try { await window.explorer.setTheme('invalid'); return false; } catch { return true; } }), true);
  assert.equal(await fs.readFile(preference, 'utf8'), saved);
  console.log('PASS: light override, persisted system mode, simulated live system-color changes, rejected invalid IPC');

  await choose('深色', 'dark'); await dark(true);
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(820, 600));
  await openAppearance();
  assert.equal(await page.locator('.context-menu').evaluateAll(menus => menus.every(menu => { const r = menu.getBoundingClientRect(); return r.left >= 0 && r.top >= 0 && r.right <= innerWidth && r.bottom <= innerHeight; })), true);
  await page.screenshot({ path: 'artifacts/theme-dark-compact.png' });
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  await page.getByRole('button', { name: '关闭预览', exact: true }).click();
  await page.getByRole('button', { name: '大图标视图', exact: true }).click();
  await page.screenshot({ path: 'artifacts/theme-dark-icons.png' });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.deepEqual(errors, []);
  console.log('PASS: dark icons, compact viewport, preserved files and no renderer errors');
  await fs.writeFile(`artifacts/${process.env.EXPLORER_APP_PATH ? 'packaged-' : ''}theme-result.json`, JSON.stringify({ passed: true, executable: process.env.EXPLORER_APP_PATH || 'source build', testedAt: new Date().toISOString(), systemChangeTest: 'fixture renderer media emulation; macOS settings unchanged', errors }, null, 2));
} catch (error) { await page?.screenshot({ path: 'artifacts/theme-failure.png' }).catch(() => {}); throw error; }
finally { await app?.close(); await fs.rm(root, { recursive: true, force: true }); }
