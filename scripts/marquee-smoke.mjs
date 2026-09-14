import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-marquee-'));
await fs.mkdir(path.join(root, 'Documents'));
for (let i = 0; i < 100; i++) await fs.writeFile(path.join(root, 'Documents', `文件-${String(i).padStart(3, '0')}.txt`), 'fixture');
const app = await electron.launch({ ...(process.env.EXPLORER_APP_PATH ? { executablePath: process.env.EXPLORER_APP_PATH, args: [] } : { args: [process.cwd()] }), env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_HIDDEN: '1' } });
try {
  const page = await app.firstWindow(); page.setDefaultTimeout(10000);
  const area = page.locator('.file-content');
  const selected = () => page.locator('.file-row[aria-selected=true]').evaluateAll(rows => rows.map(row => row.dataset.path).sort());
  async function layout(view) {
    await page.evaluate(view => { localStorage.setItem('view', JSON.stringify(view)); localStorage.setItem('iconSize', '64'); }, view);
    await page.reload(); await page.locator('.file-row').first().waitFor();
  }
  async function geometry() {
    return area.evaluate(el => ({ left: el.getBoundingClientRect().left, top: el.getBoundingClientRect().top, height: el.clientHeight, rows: [...el.querySelectorAll('.file-row')].map(row => { const r = row.getBoundingClientRect(); return { path: row.dataset.path, x: r.x, y: r.y, width: r.width, height: r.height }; }) }));
  }
  async function drag(reverse = false, modifier) {
    const g = await geometry(); const first = g.rows[0], second = g.rows[1];
    let start = { x: g.left + 2, y: first.y + 2 };
    let end = { x: second.x + second.width / 2, y: second.y + second.height - 2 };
    // Reverse begins in the left gutter below the second row.
    if (reverse) { start = { x: g.left + 2, y: second.y + second.height - 2 }; end = { x: first.x + first.width / 2, y: first.y + 2 }; }
    const hits = g.rows.filter(r => r.x < Math.max(start.x,end.x) && r.x+r.width > Math.min(start.x,end.x) && r.y < Math.max(start.y,end.y) && r.y+r.height > Math.min(start.y,end.y)).map(r => r.path).sort();
    if (modifier) await page.keyboard.down(modifier);
    await page.mouse.move(start.x, start.y); await page.mouse.down(); await page.mouse.move(end.x, end.y, { steps: 8 });
    await page.locator('.selection-marquee').waitFor();
    await page.mouse.up(); if (modifier) await page.keyboard.up(modifier);
    await page.waitForFunction(() => !document.querySelector('.selection-marquee'));
    return hits;
  }
  for (const view of ['icons', 'details', 'list', 'tiles', 'content']) {
    await layout(view);
    let hits = await drag(); assert.deepEqual(await selected(), hits, `${view}: rectangle selection survives mouseup`);
    await drag(false, 'Meta'); assert.deepEqual(await selected(), [], `${view}: Command toggles selection`);
    hits = await drag(true); assert.deepEqual(await selected(), hits, `${view}: reverse drag`);
    const added = await drag(false, 'Shift'); assert.deepEqual(await selected(), [...new Set([...hits, ...added])].sort(), `${view}: Shift adds selection`);
    const before = await selected(), g = await geometry();
    await page.mouse.move(g.left+2,g.rows[0].y+2); await page.mouse.down(); await page.mouse.move(g.left+180,g.rows[0].y+80,{steps:5});
    await page.keyboard.press('Escape'); await page.mouse.up(); assert.deepEqual(await selected(),before, `${view}: Escape restores selection`);
    assert.equal(await page.locator('.selection-marquee').count(),0);
  }
  await layout('icons');
  const g = await geometry();
  await page.mouse.move(g.left+2,g.rows[0].y+2); await page.mouse.down(); await page.mouse.move(g.left+190,g.top+g.height+40,{steps:10});
  await page.waitForFunction(() => document.querySelector('.file-content').scrollTop > 150);
  await page.mouse.up(); assert.ok((await selected()).length > 2, 'edge scroll extends selection');
  await area.evaluate(el => el.scrollTop = 0);
  await page.locator('.file-row').first().click();
  await page.evaluate(() => document.addEventListener('dragstart', e => { window.testDragPaths = e.dataTransfer.getData('application/x-explorer-paths'); e.preventDefault(); }, { once: true }));
  const row = await page.locator('.file-row').first().boundingBox();
  await page.mouse.move(row.x+row.width/2,row.y+30); await page.mouse.down(); await page.mouse.move(row.x+row.width/2+60,row.y+90,{steps:10}); await page.mouse.up();
  assert.equal(JSON.parse(await page.evaluate(() => window.testDragPaths)).length,1, 'file drag remains available');
  assert.equal(await page.locator('.selection-marquee').count(),0);
  await fs.mkdir('artifacts',{recursive:true});
  await page.mouse.move(g.left+2,g.rows[0].y+2); await page.mouse.down(); await page.mouse.move(g.left+330,g.rows[0].y+180,{steps:8});
  await page.locator('.selection-marquee').waitFor(); await page.screenshot({path:'artifacts/marquee-selection-fixture.png'}); await page.mouse.up();
  console.log('PASS: all layouts, reverse drag, Command toggle, Shift add, Escape, edge scroll, release persistence and existing file drag.');
} finally { await app.close(); await fs.rm(root,{recursive:true,force:true}); }
