import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-document-icons-'));
const docs = path.join(root, 'Documents');
await fs.mkdir(docs);
await fs.writeFile(path.join(docs, '说明.PDF'), '%PDF-1.4\nIcon test fixture');
const app = await electron.launch({ colorScheme: null, ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root } });
const page = await app.firstWindow();
const errors = [];
page.on('pageerror', error => errors.push(error.message));
try {
  await page.getByRole('option', { name: '说明.PDF', exact: true }).waitFor();
  const fixtures = await page.evaluate(() => {
    const canvas = document.createElement('canvas'); canvas.width = 240; canvas.height = 120;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ff0000'; ctx.fillRect(0, 0, 120, 120);
    ctx.fillStyle = '#0000ff'; ctx.fillRect(120, 0, 120, 120);
    const png = canvas.toDataURL('image/png'), jpeg = canvas.toDataURL('image/jpeg'), webp = canvas.toDataURL('image/webp');
    ctx.clearRect(0, 0, 240, 120); ctx.fillStyle = 'rgba(0,0,0,0.3)'; ctx.fillRect(0, 0, 240, 120);
    const alpha = canvas.toDataURL('image/png');
    ctx.fillStyle = '#00ff00'; ctx.fillRect(0, 0, 240, 120);
    return { png, jpeg, webp, alpha, updated: canvas.toDataURL('image/png') };
  });
  for (const ext of ['png', 'jpeg', 'webp']) await fs.writeFile(path.join(docs, `图片.${ext}`), Buffer.from(fixtures[ext].split(',')[1], 'base64'));
  await fs.writeFile(path.join(docs, '透明.png'), Buffer.from(fixtures.alpha.split(',')[1], 'base64'));
  for (const ext of ['heic', 'tiff', 'gif', 'bmp']) execFileSync('sips', ['-s', 'format', ext, path.join(docs, '图片.png'), '--out', path.join(docs, `图片.${ext}`)], { stdio: 'ignore' });
  // EXIF orientation 6 rotates the landscape JPEG into portrait.
  const jpeg = Buffer.from(fixtures.jpeg.split(',')[1], 'base64');
  const exif = Buffer.from('ffe1002245786966000049492a0008000000010012010300010000000600000000000000', 'hex');
  await fs.writeFile(path.join(docs, '旋转.jpeg'), Buffer.concat([jpeg.subarray(0, 2), exif, jpeg.subarray(2)]));
  await fs.writeFile(path.join(docs, '损坏.png'), 'Not a valid image');
  await page.keyboard.press('F5');
  await page.getByRole('option', { name: '图片.png', exact: true }).waitFor();

  async function measure(name, pixels = 256) {
    return page.evaluate(async ({ file, pixels }) => {
      const data = await window.explorer.icon(file, pixels);
      const img = new Image(); img.src = data; await img.decode();
      const canvas = document.createElement('canvas'); canvas.width = img.width; canvas.height = img.height;
      const ctx = canvas.getContext('2d'); ctx.drawImage(img, 0, 0);
      const values = ctx.getImageData(0, 0, img.width, img.height).data;
      let minX = img.width, minY = img.height, maxX = -1, maxY = -1;
      for (let y = 0; y < img.height; y++) for (let x = 0; x < img.width; x++) if (values[(y * img.width + x) * 4 + 3]) {
        minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
      }
      const sample = x => Array.from(ctx.getImageData(Math.round(img.width * x), Math.floor(img.height / 2), 1, 1).data);
      return { data, width: img.width, height: img.height, bounds: [maxX - minX + 1, maxY - minY + 1], left: sample(0.25), right: sample(0.75), center: sample(0.5) };
    }, { file: path.join(docs, name), pixels });
  }
  for (const ext of ['png', 'jpeg', 'webp', 'heic', 'tiff', 'gif', 'bmp']) {
    const result = await measure(`图片.${ext}`);
    assert.equal(result.width, 256); assert.equal(result.height, 256);
    assert.deepEqual(result.bounds, [256, 128], ext);
    assert.ok(result.left[0] > 200 && result.left[2] < 40, `${ext}: red image content`);
    assert.ok(result.right[2] > 200 && result.right[0] < 40, `${ext}: blue image content`);
  }
  assert.deepEqual((await measure('旋转.jpeg')).bounds, [128, 256]);
  assert.ok(Math.abs((await measure('透明.png')).center[3] - 77) <= 2, 'thumbnail opacity must not be attenuated as a shadow');
  assert.ok((await measure('损坏.png')).bounds[0] > 0, 'corrupt image falls back to a system icon');
  console.log('PASS: PNG/JPEG/WebP/HEIC/TIFF/GIF/BMP contents, aspect ratio, EXIF orientation, transparency and corrupt-image fallback');

  const before = await measure('图片.png');
  await fs.writeFile(path.join(docs, '图片.png'), Buffer.from(fixtures.updated.split(',')[1], 'base64'));
  const changed = new Date(Date.now() + 2000); await fs.utimes(path.join(docs, '图片.png'), changed, changed);
  const after = await measure('图片.png');
  assert.notEqual(after.data, before.data); assert.ok(after.center[1] > 240);
  await page.keyboard.press('F5');
  await page.waitForFunction(expected => Array.from(document.querySelectorAll('[data-path]')).find(el => el.getAttribute('data-path')?.endsWith('/图片.png'))?.querySelector('img')?.src === expected, (await measure('图片.png', 64)).data);
  console.log('PASS: rewriting a file invalidates the icon cache and refreshes the displayed thumbnail');

  for (const [label, size] of [['小图标', 32], ['中图标', 48], ['大图标', 64], ['超大图标', 128]]) {
    await page.getByRole('button', { name: '查看', exact: true }).click();
    await page.getByRole('menuitemradio', { name: label, exact: true }).click();
    const pdf = page.getByRole('option', { name: '说明.PDF', exact: true }).locator('svg.pdf-glyph');
    assert.equal(await pdf.evaluate(el => el.getBoundingClientRect().width), size);
    assert.equal(await pdf.locator('rect').getAttribute('fill'), '#b30b00');
  }
  await fs.mkdir('artifacts', { recursive: true });
  await page.screenshot({ path: 'artifacts/document-icons-light.png' });
  await page.evaluate(() => window.explorer.setTheme('dark')); await page.reload();
  await page.locator('svg.pdf-glyph').waitFor();
  await page.waitForFunction(() => getComputedStyle(document.body).backgroundColor === 'rgb(25, 25, 25)');
  await page.screenshot({ path: 'artifacts/document-icons-dark.png' });
  assert.deepEqual(errors, []);
  console.log('PASS: custom PDF vector renders at all four sizes; light/dark screenshots captured');
} finally {
  await app.close();
  await fs.rm(root, { recursive: true, force: true });
}
