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
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MAC_EXPLORER_INSTALL_DIR: installDir, MAC_EXPLORER_NO_OPEN: '1', TEST_FIXTURES: path.resolve(fixture) };
  const run = extra => exec('/bin/bash', ['scripts/install.sh'], { env: { ...env, ...extra }, maxBuffer: 1024 * 1024 });
  const app = path.join(installDir, 'Mac Explorer.app');
  await run();
  await exec('codesign', ['--verify', '--deep', '--strict', app]);
  const original = await fs.readFile(path.join(app, 'Contents/Info.plist'));
  await run(); // Updating retains a complete backup.
  assert.equal((await fs.readdir(path.join(installDir, '.Mac Explorer Backups'))).length, 1);
  for (const extra of [{ TEST_CORRUPT: '1' }, { TEST_NETWORK_FAILURE: '1' }, { TEST_RUNNING: '1' }, { TEST_MOVE_FAILURE: '1' }]) {
    await assert.rejects(run(extra));
    assert.deepEqual(await fs.readFile(path.join(app, 'Contents/Info.plist')), original);
    await exec('codesign', ['--verify', '--deep', '--strict', app]);
  }
  assert.equal((await fs.readdir(installDir)).some(name => name.startsWith('.mac-explorer-install.')), false);
  console.log('PASS: first install, update backup, corrupted download/network/running-app guards, failed replacement rollback; all targets are temporary, no app launched.');
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
