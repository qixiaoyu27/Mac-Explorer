import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-swipe-'));
for (const folder of ['Documents/A/B', 'Desktop', 'Downloads']) await fs.mkdir(path.join(root, folder), { recursive: true });
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  const page = await app.firstWindow(); page.setDefaultTimeout(15000);
  const content = page.locator('.file-content');
  const at = async name => page.locator(`.file-content[aria-label="${name}"][aria-busy="false"]`).waitFor();
  const pause = () => page.waitForTimeout(300); // Separate physical wheel gestures.
  const wheel = async (deltaX, deltaY = 0, options = {}, selector = '.file-content') => page.locator(selector).dispatchEvent('wheel', { deltaX, deltaY, deltaMode: 0, bubbles: true, cancelable: true, ...options });
  const unchanged = async name => { await page.waitForTimeout(80); assert.equal(await content.getAttribute('aria-label'), name); };
  await page.getByRole('option', { name: 'A', exact: true }).dblclick(); await at('A');
  await page.getByRole('option', { name: 'B', exact: true }).dblclick(); await at('B');
  // Real Chromium wheel input, plus a momentum tail crossing a React render.
  await content.hover(); await page.mouse.wheel(-110, 0); await at('A');
  await wheel(-180); await wheel(-100); await unchanged('A');
  await pause(); await wheel(110); await at('B');
  await pause(); await wheel(110); await unchanged('B'); // End of history.
  await pause(); await wheel(-30); await wheel(-30); await unchanged('B');
  await wheel(-35); await at('A'); // Small deltas accumulate.
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
