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
  await stub('curl', `headers=''; output=''; url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump-header) headers="$2"; shift 2;;
    -o) output="$2"; shift 2;;
    https://*) url="$1"; shift;;
    *) shift;;
  esac
done
if [[ "\${TEST_NETWORK_FAILURE:-0}" == 1 ]]; then exit 22; fi
if [[ "$url" == *.zip ]]; then
  printf 'zip\\n' >> "$TEST_DOWNLOAD_LOG"
  if [[ "\${TEST_ZIP_FAILURE:-0}" == 1 ]]; then exit 22; fi
  if [[ "\${TEST_UNKNOWN_SIZE:-0}" == 1 ]]; then printf 'HTTP/2 200\\r\\n\\r\\n' > "$headers"
  else printf 'HTTP/2 302\\r\\nContent-Length: 10\\r\\n\\r\\nHTTP/2 200\\r\\nContent-Length: %s\\r\\n\\r\\n' "$(stat -f%z "$TEST_FIXTURES/\${url##*/}")" > "$headers"; fi
  sleep 1
fi
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
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, MAC_EXPLORER_INSTALL_DIR: installDir, MAC_EXPLORER_NO_OPEN: '1', MAC_EXPLORER_ALLOW_UNNOTARIZED: '0', TEST_DOWNLOAD_LOG: path.join(root, 'downloads'), TEST_FIXTURES: path.resolve(fixture) };
  const run = extra => exec('/bin/bash', ['scripts/install.sh'], { env: { ...env, ...extra }, maxBuffer: 1024 * 1024 });
  const app = path.join(installDir, 'Mac Explorer.app');
  const firstInstall = await run();
  assert.equal((firstInstall.stdout.match(/⭐ Star/g) || []).length, 1);
  assert.match(firstInstall.stdout, /✓ 安装完成/);
  assert.match(firstInstall.stdout, /╭─ MAC EXPLORER/);
  assert.match(firstInstall.stdout, /https:\/\/github.com\/qixiaoyu27\/Mac-Explorer/);
  assert.equal(firstInstall.stdout.includes('\x1b['), false); // Redirected output has no ANSI codes.
  await exec('codesign', ['--verify', '--deep', '--strict', app]);
  assert.match((await exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', app])).stdout, /InstallerTest/);
  assert.match(firstInstall.stdout, /【[\d.]+ MiB】\/【[\d.]+ MiB】   【100%】/);
  const original = await fs.readFile(path.join(app, 'Contents/Info.plist'));
  const setVersion = async version => {
    await exec('/usr/libexec/PlistBuddy', ['-c', `Set CFBundleShortVersionString ${version}`, path.join(app, 'Contents/Info.plist')]);
    await exec('codesign', ['--force', '--deep', '--sign', '-', app]);
    return fs.readFile(path.join(app, 'Contents/Info.plist'));
  };
  const downloads = await fs.readFile(env.TEST_DOWNLOAD_LOG, 'utf8');
  assert.match((await run({ TEST_RUNNING: '1' })).stdout, /已是最新版/);
  await setVersion('99.0.0');
  assert.match((await run()).stdout, /不降级/);
  assert.equal(await fs.readFile(env.TEST_DOWNLOAD_LOG, 'utf8'), downloads);
  await setVersion('0.1.9'); // Numeric, not lexicographic comparison.
  assert.match((await run()).stdout, /发现新版本/);
  assert.equal((await fs.readdir(path.join(installDir, '.Mac Explorer Backups'))).length, 1);
  for (const extra of [{ TEST_CORRUPT: '1' }, { TEST_NETWORK_FAILURE: '1' }, { TEST_RUNNING: '1' }, { TEST_MOVE_FAILURE: '1' }, { TEST_ZIP_FAILURE: '1' }]) {
    const older = await setVersion('0.1.9');
    await assert.rejects(run(extra), error => {
      if (extra.TEST_ZIP_FAILURE) assert.doesNotMatch(error.stdout, /【100%】/);
      return true;
    });
    assert.deepEqual(await fs.readFile(path.join(app, 'Contents/Info.plist')), older);
    await exec('codesign', ['--verify', '--deep', '--strict', app]);
  }
  assert.deepEqual((await fs.readdir(installDir)).filter(name => name.startsWith('.mac-explorer-install.')), []);
  const unrelated = path.join(root, 'unrelated'); await fs.writeFile(unrelated, 'preserved');
  await exec('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0081;00000000;Unrelated;', unrelated]);
  const optInInstall = await run({ MAC_EXPLORER_ALLOW_UNNOTARIZED: '1', TEST_UNKNOWN_SIZE: '1' });
  assert.match(optInInstall.stdout, /【100%】/);
  assert.equal((optInInstall.stdout.match(/⭐ Star/g) || []).length, 1);
  await assert.rejects(exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', app]));
  assert.equal((await exec('/usr/bin/xattr', ['-p', 'com.macexplorer.installer-test', app])).stdout.trim(), 'preserved');
  assert.match((await exec('/usr/bin/xattr', ['-p', 'com.apple.quarantine', unrelated])).stdout, /Unrelated/);
  await exec('codesign', ['--verify', '--deep', '--strict', app]);
  assert.deepEqual(await fs.readFile(path.join(app, 'Contents/Info.plist')), original);
  const older = await setVersion('0.1.9');
  await assert.rejects(run({ MAC_EXPLORER_ALLOW_UNNOTARIZED: '1', TEST_CORRUPT: '1' }));
  assert.deepEqual(await fs.readFile(path.join(app, 'Contents/Info.plist')), older);
  console.log('PASS: install/update/rollback, default quarantine preserved, explicit opt-in removes only application quarantine, unrelated attributes/files preserved, corrupt opt-in download rejected; temporary fixtures only, no app launched.');
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
