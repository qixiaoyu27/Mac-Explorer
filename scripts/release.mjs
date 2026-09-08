import { build, Platform, Arch } from 'electron-builder';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';

const exec = promisify(execFile);
const pkg = JSON.parse(await fs.readFile('package.json', 'utf8'));
// Always use ad-hoc signing, even when the shell has release credentials set.
process.env.CSC_IDENTITY_AUTO_DISCOVERY = 'false';
for (const key of ['CSC_NAME', 'CSC_LINK', 'CSC_KEYCHAIN', 'CSC_KEY_PASSWORD', 'APPLE_NOTARY_PROFILE', 'APPLE_API_KEY', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER', 'APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID']) delete process.env[key];
const output = path.resolve(`release/adhoc-${pkg.version}`);
const app = path.join(output, 'mac-arm64', `${pkg.build.productName}.app`);
const stem = `Mac-Explorer-${pkg.version}-mac-arm64`;
const zip = path.join(output, `${stem}.zip`);
const dmg = path.join(output, `${stem}.dmg`);
async function run(command, args) {
  const result = await exec(command, args, { maxBuffer: 8 * 1024 * 1024 });
  if (result.stdout.trim()) console.log(result.stdout.trim());
  return result.stdout;
}
await build({ targets: Platform.MAC.createTarget(['dir'], Arch.arm64), publish: 'never', config: {
  ...pkg.build, directories: { output }, forceCodeSigning: false,
  mac: { ...pkg.build.mac, identity: null, notarize: false },
} });
for (const name of ['file-icon', 'archive-reader']) {
  await run('codesign', ['--force', '--sign', '-', path.join(app, 'Contents/Resources/app.asar.unpacked/dist-electron/native', name)]);
}
await run('codesign', ['--force', '--deep', '--sign', '-', app]);
await run('codesign', ['--verify', '--deep', '--strict', app]);
const signature = await exec('codesign', ['-dv', '--verbose=4', app]);
if (!signature.stderr.includes('Signature=adhoc') || signature.stderr.includes('Authority=')) throw new Error('Expected an ad-hoc signature without a certificate');
await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
await fs.symlink('/Applications', path.join(output, 'mac-arm64', 'Applications')).catch(error => { if (error.code !== 'EEXIST') throw error; });
await run('hdiutil', ['create', '-volname', 'Mac Explorer', '-srcfolder', path.dirname(app), '-ov', '-format', 'UDZO', dmg]);
await run('codesign', ['--force', '--sign', '-', dmg]);
await run('codesign', ['--verify', '--strict', dmg]);
await run('hdiutil', ['verify', dmg]);
const checksums = await Promise.all([dmg, zip].map(async file => `${createHash('sha256').update(await fs.readFile(file)).digest('hex')}  ${path.basename(file)}`));
await fs.writeFile(path.join(output, 'SHA256SUMS.txt'), `${checksums.join('\n')}\n`);
console.log(`Ad-hoc signed, unnotarized release ready: ${output}`);
