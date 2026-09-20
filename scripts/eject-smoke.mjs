import { _electron as electron } from 'playwright';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-eject-'));
const helper = path.resolve('dist-electron/native/volumes');
const name = `Explorer Eject ${Date.now()}`;
let mount; let app; let held;
try {
  await fs.mkdir(path.join(root, 'Documents'));
  execFileSync('/usr/bin/hdiutil', ['create', '-size', '16m', '-fs', 'HFS+', '-volname', name, path.join(root, 'fixture.dmg')]);
  const attached = execFileSync('/usr/bin/hdiutil', ['attach', '-nobrowse', '-plist', path.join(root, 'fixture.dmg')]);
  const info = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], { input: attached, encoding: 'utf8' }));
  mount = info['system-entities'].find(item => item['mount-point'])['mount-point'];
  assert.equal(JSON.parse(execFileSync(helper, ['list'], { encoding: 'utf8' })).find(volume => volume.path === mount).canEject, true);
  assert.throws(() => execFileSync(helper, ['eject', '/'], { stdio: 'pipe' }), /Command failed/);
  assert.throws(() => execFileSync(helper, ['eject', root], { stdio: 'pipe' }), /Command failed/);
  await fs.writeFile(path.join(mount, 'fixture.txt'), 'eject fixture');
  app = await electron.launch({ args: [process.cwd()], env: { ...process.env, EXPLORER_TEST_ROOT: root, EXPLORER_TEST_EJECT_VOLUME: mount, EXPLORER_TEST_HIDDEN: '1' } });
  const page = await app.firstWindow(); page.setDefaultTimeout(15000);
  const nav = page.locator('.sidebar').getByRole('button', { name, exact: true });
  await nav.waitFor();
  assert.equal(await page.getByRole('button', { name: '推出“Macintosh HD”', exact: true }).count(), 0);
  await nav.click({ button: 'right' }); await page.getByRole('menuitem', { name: `推出“${name}”`, exact: true }).waitFor();
  await page.keyboard.press('Escape');
  await nav.click(); await page.getByRole('option', { name: 'fixture.txt', exact: true }).waitFor();
  await page.screenshot({ path: 'artifacts/eject-fixture.png' });
  // Keep a real open file descriptor on this temporary volume to exercise a busy disk.
  held = await fs.open(path.join(mount, 'fixture.txt'), 'r');
  await page.getByRole('button', { name: `推出“${name}”`, exact: true }).click();
  await page.getByRole('alert').filter({ hasText: '无法推出磁盘' }).waitFor();
  assert.equal(await fs.readFile(path.join(mount, 'fixture.txt'), 'utf8'), 'eject fixture');
  await held.close(); held = null;
  await page.getByRole('button', { name: `推出“${name}”`, exact: true }).click();
  await nav.waitFor({ state: 'detached' });
  await page.locator('.file-content[aria-label="个人文件夹"][aria-busy=false]').waitFor();
  assert.equal(JSON.parse(execFileSync(helper, ['list'], { encoding: 'utf8' })).some(volume => volume.path === mount), false);
  console.log('PASS: native volume capabilities, protected paths, sidebar eject button, context menu, real busy-volume failure without data loss, real DMG eject, list and tab refresh.');
} finally {
  if (held) await held.close();
  if (app) await app.close();
  if (mount) { try { execFileSync('/usr/bin/hdiutil', ['detach', mount], { stdio: 'pipe' }); } catch {} }
  await fs.rm(root, { recursive: true, force: true });
}
