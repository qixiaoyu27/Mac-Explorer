import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'explorer-installer-test-'));
const installDir = path.join(root, 'Applications');
const bin = path.join(root, 'bin');
const fixture = process.env.EXPLORER_INSTALLER_FIXTURES;
if (!fixture) throw new Error('Set EXPLORER_INSTALLER_FIXTURES to a release directory containing ZIP and SHA256SUMS.txt.');
try {
  await fs.mkdir(bin);
  const stub = async (name, source) => fs.writeFile(path.join(bin, name), `#!/bin/bash\nset -eu\n${source}\n`, { mode: 0o755 });
  await stub('pgrep', '[[ "${TEST_RUNNING:-0}" == 1 ]]');
  await stub('curl', `url="\${@: -3:1}"; output="\${@: -1}"
if [[ "\${TEST_NETWORK_FAILURE:-0}" == 1 ]]; then exit 22; fi
cp "$TEST_FIXTURES/\${url##*/}" "$output"
if [[ "\${TEST_CORRUPT:-0}" == 1 && "$url" == *.zip ]]; then printf damaged >> "$output"; fi`);
  await stub('mv', `if [[ "\${TEST_MOVE_FAILURE:-0}" == 1 && "$1" == */.mac-explorer-install.*/"Mac Explorer.app" ]]; then exit 1; fi
exec /bin/mv "$@"`);
  await stub('ditto', `/usr/bin/ditto "$@"
target="\${@: -1}"
if [[ "$target" == *.app ]]; then
  /usr/bin/xattr -w com.apple.quarantine '0081;00000000;InstallerTest;' "$target"
  /usr/bin/xattr -w com.macexplorer.installer-test preserved "$target"
fi`);
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MAC_EXPLORER_INSTALL_DIR: installDir, MAC_EXPLORER_NO_OPEN: '1', MAC_EXPLORER_ALLOW_UNNOTARIZED: '0', TEST_FIXTURES: path.resolve(fixture) };
  const run = extra => exec('/bin/bash', ['scripts/install.sh'], { env: { ...env, ...extra }, maxBuffer: 1024 * 1024 });
  const app = path.join(installDir, 'Mac Explorer.app');
  await run();
  await exec('codesign', ['--verify', '--deep', '--strict', app]);
  assert.match((await exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', app])).stdout, /InstallerTest/);
  const original = await fs.readFile(path.join(app, 'Contents/Info.plist'));
  await run(); // Updating retains a complete backup.
  assert.equal((await fs.readdir(path.join(installDir, '.Mac Explorer Backups'))).length, 1);
  for (const extra of [{ TEST_CORRUPT: '1' }, { TEST_NETWORK_FAILURE: '1' }, { TEST_RUNNING: '1' }, { TEST_MOVE_FAILURE: '1' }]) {
    await assert.rejects(run(extra));
    assert.deepEqual(await fs.readFile(path.join(app, 'Contents/Info.plist')), original);
    await exec('codesign', ['--verify', '--deep', '--strict', app]);
  }
  assert.equal((await fs.readdir(installDir)).some(name => name.startsWith('.mac-explorer-install.')), false);
  const unrelated = path.join(root, 'unrelated'); await fs.writeFile(unrelated, 'preserved');
  await exec('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0081;00000000;Unrelated;', unrelated]);
  await run({ MAC_EXPLORER_ALLOW_UNNOTARIZED: '1' });
  await assert.rejects(exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', app]));
  assert.equal((await exec('/usr/bin/xattr', ['-p', 'com.macexplorer.installer-test', app])).stdout.trim(), 'preserved');
  assert.match((await exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', unrelated])).stdout, /Unrelated/);
  await exec('codesign', ['--verify', '--deep', '--strict', app]);
  await assert.rejects(run({ MAC_EXPLORER_ALLOW_UNNOTARIZED: '1', TEST_CORRUPT: '1' }));
  assert.deepEqual(await fs.readFile(path.join(app, 'Contents/Info.plist')), original);
  console.log('PASS: install/update/rollback, default quarantine preserved, explicit opt-in removes only application quarantine, unrelated attributes/files preserved, corrupt opt-in download rejected; temporary fixtures only, no app launched.');
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
