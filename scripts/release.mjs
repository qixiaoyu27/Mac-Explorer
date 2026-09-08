import { build, Platform, Arch } from 'electron-builder';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';

const exec = promisify(execFile);
const pkg = JSON.parse(await fs.readFile('package.json', 'utf8'));
const identity = process.env.CSC_NAME;
const profile = process.env.APPLE_NOTARY_PROFILE;
if (!identity || !profile) throw new Error('Set CSC_NAME and APPLE_NOTARY_PROFILE for a signed, notarized release.');
const output = path.resolve(`release/formal-${pkg.version}`);
const app = path.join(output, 'mac-arm64', `${pkg.build.productName}.app`);
const stem = `Mac-Explorer-${pkg.version}-mac-arm64`;
const zip = path.join(output, `${stem}.zip`);
const dmg = path.join(output, `${stem}.dmg`);
async function run(command, args) {
  const result = await exec(command, args, { maxBuffer: 8 * 1024 * 1024 });
  if (result.stdout.trim()) console.log(result.stdout.trim());
  return result.stdout;
}
async function notarize(artifact) {
  console.log(`Submitting ${path.basename(artifact)} to Apple…`);
  const result = JSON.parse(await run('xcrun', ['notarytool', 'submit', artifact, '--keychain-profile', profile, '--wait', '--output-format', 'json']));
  await fs.writeFile(`${artifact}.notary.json`, JSON.stringify(result, null, 2));
  if (result.status !== 'Accepted') throw new Error(`Apple notarization returned ${result.status}; artifact will not be published.`);
}
await build({ targets: Platform.MAC.createTarget(['dir'], Arch.arm64), publish: 'never', config: {
  ...pkg.build, directories: { output }, forceCodeSigning: true,
  mac: { ...pkg.build.mac, identity, hardenedRuntime: true, notarize: false,
    entitlements: 'electron/entitlements.mac.plist', entitlementsInherit: 'electron/entitlements.mac.plist' },
} });
await run('codesign', ['--verify', '--deep', '--strict', app]);
// Confirm the unpacked native services were signed too, before submitting.
for (const name of ['file-icon', 'archive-reader']) {
  const signature = await exec('codesign', ['-dv', '--verbose=4', path.join(app, 'Contents/Resources/app.asar.unpacked/dist-electron/native', name)]);
  if (!signature.stderr.includes('Authority=Developer ID Application:')) throw new Error(`${name} lacks Developer ID signing`);
}
await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
await notarize(zip);
await run('xcrun', ['stapler', 'staple', app]);
await run('xcrun', ['stapler', 'validate', app]);
await run('spctl', ['--assess', '--type', 'execute', '--verbose=4', app]);
// Recreate ZIP so its application contains the offline notarization ticket.
await fs.unlink(zip);
await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
await fs.symlink('/Applications', path.join(output, 'mac-arm64', 'Applications')).catch(error => { if (error.code !== 'EEXIST') throw error; });
await run('hdiutil', ['create', '-volname', 'Mac Explorer', '-srcfolder', path.dirname(app), '-ov', '-format', 'UDZO', dmg]);
await run('codesign', ['--force', '--timestamp', '--sign', identity, ...(process.env.CSC_KEYCHAIN ? ['--keychain', process.env.CSC_KEYCHAIN] : []), dmg]);
await notarize(dmg);
await run('xcrun', ['stapler', 'staple', dmg]);
await run('xcrun', ['stapler', 'validate', dmg]);
await run('hdiutil', ['verify', dmg]);
await run('spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', dmg]);
const checksums = await Promise.all([dmg, zip].map(async file => `${createHash('sha256').update(await fs.readFile(file)).digest('hex')}  ${path.basename(file)}`));
await fs.writeFile(path.join(output, 'SHA256SUMS.txt'), `${checksums.join('\n')}\n`);
console.log(`Signed and notarized release ready: ${output}`);
