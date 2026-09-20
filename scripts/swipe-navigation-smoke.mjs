import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import nodeAPIHeaders from 'node-api-headers';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-swipe-'));
const nativeFixture = path.join(root, 'scroll-fixture.node');
execFileSync('xcrun', ['clang++', '-std=c++17', '-fobjc-arc', '-bundle', '-undefined', 'dynamic_lookup', '-framework', 'AppKit', '-DNAPI_VERSION=8', '-I', nodeAPIHeaders.include_dir, 'tests/fixtures/ScrollGestureFixture.mm', '-o', nativeFixture]);
for (const folder of ['Documents/A/B', 'Desktop', 'Downloads']) await fs.mkdir(path.join(root, folder), { recursive: true });
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  const page = await app.firstWindow(); page.setDefaultTimeout(15000);
  await page.evaluate(() => { window.gestureStarts = 0; window.explorer.onScrollGestureStart(() => window.gestureStarts++); });
  const content = page.locator('.file-content');
  const at = async name => page.locator(`.file-content[aria-label="${name}"][aria-busy="false"]`).waitFor();
  const pause = () => page.waitForTimeout(300); // Separate physical wheel gestures.
  const wheel = async (deltaX, deltaY = 0, options = {}, selector = '.file-content') => page.locator(selector).dispatchEvent('wheel', { deltaX, deltaY, deltaMode: 0, bubbles: true, cancelable: true, ...options });
  const unchanged = async name => { await page.waitForTimeout(80); assert.equal(await content.getAttribute('aria-label'), name); };
  const beginStroke = async timestamp => {
    const count = await page.evaluate(() => window.gestureStarts);
    if (timestamp !== undefined) {
      await app.evaluate(({ BrowserWindow }, time) => BrowserWindow.getAllWindows()[0].webContents.send('scroll-gesture-start', time), timestamp);
    } else {
      await app.evaluate((_, file) => process.getBuiltinModule('module').createRequire(file)(file).begin(), nativeFixture);
    }
    await page.waitForFunction(previous => window.gestureStarts > previous, count);
  };
  await page.getByRole('option', { name: 'A', exact: true }).dblclick(); await at('A');
  await page.getByRole('option', { name: 'B', exact: true }).dblclick(); await at('B');
  await beginStroke(); await wheel(-60); await at('A');
  await beginStroke(); await wheel(-60); await at('文档');
  await beginStroke(); await wheel(60); await at('A');
  // A delayed start notification from an earlier stroke cannot unlock momentum.
  await beginStroke(Date.now() - 1000); await wheel(80); await unchanged('A');
  await beginStroke(); await wheel(60); await at('B');
  // Keep the pointer fixed throughout consecutive real Chromium wheel inputs.
  await content.hover();
  for (const [delta, name] of [[-60, 'A'], [-60, '文档'], [60, 'A'], [60, 'B']]) {
    await pause(); await page.mouse.wheel(delta, 0); await at(name);
  }
  await pause(); await wheel(-60); await at('A');
  // A low-energy momentum tail must neither navigate nor swallow a new stroke.
  for (let i = 0; i < 8; i++) { await page.waitForTimeout(30); await wheel(-2); }
  await unchanged('A');
  await wheel(-18); await wheel(-18); await wheel(-18); await at('文档');
  await wheel(-100); await unchanged('文档');
  await pause(); await wheel(60); await at('A');
  // Phase-only events must not extend the lock indefinitely.
  for (let i = 0; i < 8; i++) { await page.waitForTimeout(40); await wheel(0); }
  await wheel(60); await at('B');
  await pause();
  // Real Chromium wheel input, plus a momentum tail crossing a React render.
  await content.hover(); await page.mouse.wheel(-110, 0); await at('A');
  await wheel(-180); await wheel(-100); await unchanged('A');
  await pause(); await wheel(110); await at('B');
  await pause(); await wheel(110); await unchanged('B'); // End of history.
  await pause(); await wheel(-12); await wheel(-16); await unchanged('B');
  await wheel(-24); await at('A'); // A short swipe accumulates without requiring 90 px.
  await pause(); await wheel(52); await at('B');
  await pause(); await wheel(-8, 10); await unchanged('B');
  await wheel(-45, 2); await at('A'); // A diagonal start can resolve into a horizontal swipe.
  await pause(); await wheel(110); await at('B');
  await pause(); await wheel(-5, 60); await wheel(-140, 0); await unchanged('B'); // Vertical intent locks.
  await pause(); await wheel(-20, 20); await unchanged('B');
  await pause(); await wheel(-150, 0, { ctrlKey: true }); await unchanged('B');
  await pause(); await wheel(-150, 0, { shiftKey: true }); await unchanged('B');
  await pause(); await wheel(-150, 0, { deltaMode: 1 }); await unchanged('B');
  await page.keyboard.press('Meta+Shift+g');
  await pause(); await wheel(-150); await unchanged('B');
  await page.getByRole('textbox', { name: '文件夹地址', exact: true }).press('Escape');
  await content.focus();
  await page.getByRole('button', { name: '新建', exact: true }).click();
  await page.getByRole('menuitem', { name: /文件夹/ }).click();
  await page.getByLabel('名称', { exact: true }).waitFor();
  await pause(); await wheel(-150); await unchanged('B');
  await page.getByLabel('名称', { exact: true }).press('Escape');
  await page.keyboard.press('Meta+Backspace'); await page.getByRole('dialog').waitFor();
  await pause(); await wheel(-150); await unchanged('B');
  await page.getByRole('button', { name: '取消', exact: true }).click();
  await content.click({ button: 'right' });
  await pause(); await wheel(-150); await unchanged('B');
  await page.keyboard.press('Escape');
  // Explicit scroll fixture checks both edges without relying on host window size.
  await content.evaluate(element => {
    const scroller = document.createElement('div'); scroller.id = 'swipe-scroll-fixture';
    scroller.style.cssText = 'width:100px;height:30px;overflow-x:auto';
    scroller.innerHTML = '<div style="width:600px;height:20px"></div>'; element.append(scroller);
  });
  await pause(); await wheel(-150, 0, {}, '#swipe-scroll-fixture'); await unchanged('B');
  await page.locator('#swipe-scroll-fixture').evaluate(element => { element.scrollLeft = 500; });
  await pause(); await wheel(150, 0, {}, '#swipe-scroll-fixture'); await unchanged('B');
  await page.locator('#swipe-scroll-fixture').evaluate(element => element.remove());
  await pause(); await wheel(-110); await at('A');
  await pause(); await wheel(-110); await at('文档');
  await pause(); await wheel(-110); await unchanged('文档'); // Start of history.
  await page.keyboard.press('Meta+]'); await at('A');
  await pause(); await wheel(110); await at('B');
  await page.keyboard.press('Meta+t'); await at('个人文件夹');
  await pause(); await wheel(-110); await unchanged('个人文件夹'); // New tab has its own history.
  console.log('PASS: real wheel back, forward, one step per momentum stream, threshold, history bounds, vertical/diagonal/modified wheel guards, address/modal/menu guards, scrollable edges, keyboard and tab history. Physical trackpad feel requires manual verification.');
} finally {
  await app.close(); await fs.rm(root, { recursive: true, force: true });
}
