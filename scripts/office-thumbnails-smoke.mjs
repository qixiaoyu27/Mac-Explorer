import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-office-icons-'));
const docs = path.join(root, 'Documents'); await fs.mkdir(docs);
for (const ext of ['docx', 'xlsx', 'pptx']) await fs.copyFile(`tests/fixtures/office/sample.${ext}`, path.join(docs, `sample.${ext}`));
await fs.writeFile(path.join(docs, 'broken.docx'), 'invalid office document');
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
 const page = await app.firstWindow();
 await page.locator('.file-content[aria-busy=false]').waitFor();
 await page.evaluate(() => { localStorage.setItem('view', '"icons"'); localStorage.setItem('iconSize', '128'); });
 await page.reload();
 for (const ext of ['docx', 'xlsx', 'pptx']) {
  const row = page.getByRole('option', { name: `sample.${ext}`, exact: true });
  await row.locator('img').waitFor();
  const data = await page.evaluate(file => window.explorer.icon(file, 512), path.join(docs, `sample.${ext}`));
  await fs.writeFile(`artifacts/office-${ext}.png`, Buffer.from(data.split(',')[1], 'base64'));
  assert.ok(data.length > 1000);
 }
 await page.getByRole('option', { name: 'broken.docx', exact: true }).locator('img').waitFor({ timeout: 15000 });
 await page.screenshot({ path: 'artifacts/office-thumbnails-fixture.png' });
 console.log('PASS: Office thumbnails render; corrupt Office file falls back; fixture screenshot captured.');
} finally { await app.close(); await fs.rm(root, { recursive: true, force: true }); }
