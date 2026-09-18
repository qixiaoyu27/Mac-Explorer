import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-thumbnail-cache-'));
await fs.mkdir(path.join(root, 'Documents'));
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
 const page = await app.firstWindow(); await page.locator('.file-content[aria-busy=false]').waitFor();
 // Count native requests, not wall-clock timing assertions susceptible to load.
 await app.evaluate(({ BrowserWindow }) => {
  const cp = process.getBuiltinModule('child_process');
  const original = cp.spawn; globalThis.iconRequests = 0;
  cp.spawn = function (...args) {
   const child = original.apply(this, args);
   if (String(args[0]).endsWith('/file-icon')) {
    const write = child.stdin.write;
    child.stdin.write = function (...values) { globalThis.iconRequests++; return write.apply(this, values); };
   }
   return child;
  };
 });
 const png = await page.evaluate(() => {
  const c = document.createElement('canvas'); c.width = 2000; c.height = 1500;
  const ctx = c.getContext('2d'); ctx.fillStyle = '#2670aa'; ctx.fillRect(0, 0, c.width, c.height);
  return c.toDataURL().split(',')[1];
 });
 const files = Array.from({ length: 24 }, (_, i) => path.join(root, `photo-${i}.png`));
 for (const file of files) await fs.writeFile(file, Buffer.from(png, 'base64'));
 const load = () => page.evaluate(async files => { const start = performance.now(); await Promise.all(files.map(file => window.explorer.icon(file, 256))); return Math.round(performance.now() - start); }, files);
 const cold = await load(); const before = await app.evaluate(() => globalThis.iconRequests);
 assert.equal(before, 24);
 await page.evaluate(root => window.explorer.list(root), root);
 const warm = await load(); assert.equal(await app.evaluate(() => globalThis.iconRequests), before);
 await fs.utimes(files[0], new Date(), new Date(Date.now() + 2000));
 await load(); assert.equal(await app.evaluate(() => globalThis.iconRequests), before + 1);
 await page.evaluate(root => window.explorer.list(root, true), root);
 await load(); assert.equal(await app.evaluate(() => globalThis.iconRequests), before + 25);
 console.log(`PASS: 24 images cold ${cold}ms, cached after directory read ${warm}ms; zero duplicate native renders; modified file rerenders once; explicit refresh invalidates.`);
} finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
