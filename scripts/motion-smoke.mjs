import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-motion-'));
await fs.mkdir(path.join(root, 'Documents'));
await fs.writeFile(path.join(root, 'Documents', 'example.txt'), 'Motion fixture');
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  const page = await app.firstWindow();
  await page.locator('.file-content[aria-busy=false]').waitFor();
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  // Capture actual Web Animations calls, including rapid view interruptions.
  await page.evaluate(() => {
    window.motionCalls = [];
    const animate = Element.prototype.animate;
    Element.prototype.animate = function (...args) {
      window.motionCalls.push({ className: this.className, duration: args[1].duration });
      return animate.apply(this, args);
    };
  });
  await page.getByRole('option', { name: 'example.txt', exact: true }).click();
  for (const name of ['大图标视图', '详细信息视图', '大图标视图']) await page.getByRole('button', { name, exact: true }).click();
  assert.equal(await page.getByRole('option', { name: 'example.txt', exact: true }).getAttribute('aria-selected'), 'true');
  assert.ok(await page.evaluate(() => window.motionCalls.some(call => call.duration === 167 && call.className.includes('file-items'))));
  await page.getByRole('button', { name: '查看', exact: true }).click();
  assert.equal(await page.locator('.context-menu').first().evaluate(el => getComputedStyle(el).animationName), 'surface-appear');
  await page.keyboard.press('Escape');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.evaluate(() => { window.motionCalls = []; });
  await page.getByRole('button', { name: '详细信息视图', exact: true }).click();
  assert.equal(await page.evaluate(() => window.motionCalls.length), 0);
  await page.getByRole('button', { name: '查看', exact: true }).click();
  assert.equal(await page.locator('.context-menu').first().evaluate(el => getComputedStyle(el).animationName), 'none');
  await page.screenshot({ path: 'artifacts/motion-menu-fixture.png' });
  console.log('PASS: view transitions, interrupted switches, selection preservation, menu motion, reduced motion.');
} finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
