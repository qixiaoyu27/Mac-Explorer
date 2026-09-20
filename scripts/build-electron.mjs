import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import nodeAPIHeaders from 'node-api-headers';

fs.mkdirSync('dist-electron/native', { recursive: true });
const gestureSource = 'electron/native/ScrollGesture.mm';
const gestureBinary = 'dist-electron/native/scroll-gesture.node';
if (!fs.existsSync(gestureBinary) || Math.max(fs.statSync(gestureSource).mtimeMs, fs.statSync('scripts/build-electron.mjs').mtimeMs) > fs.statSync(gestureBinary).mtimeMs) {
  execFileSync('xcrun', ['clang++', '-target', 'arm64-apple-macos13.0', '-std=c++17', '-fobjc-arc', '-O2', '-bundle', '-undefined', 'dynamic_lookup', '-framework', 'AppKit', '-DNAPI_VERSION=8', '-I', nodeAPIHeaders.include_dir, gestureSource, '-o', gestureBinary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', gestureBinary], { stdio: 'inherit' });
}
const source = 'electron/native/FileIcon.swift';
const binary = 'dist-electron/native/file-icon';
if (!fs.existsSync(binary) || Math.max(fs.statSync(source).mtimeMs, fs.statSync('scripts/build-electron.mjs').mtimeMs) > fs.statSync(binary).mtimeMs) {
  execFileSync('xcrun', ['swiftc', '-target', 'arm64-apple-macos13.0', '-O', source, '-o', binary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', binary], { stdio: 'inherit' });
}
const trashSource = 'electron/native/TrashItem.swift';
const trashBinary = 'dist-electron/native/trash-item';
if (!fs.existsSync(trashBinary) || fs.statSync(trashSource).mtimeMs > fs.statSync(trashBinary).mtimeMs) {
  execFileSync('xcrun', ['swiftc', '-target', 'arm64-apple-macos13.0', '-O', trashSource, '-o', trashBinary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', trashBinary], { stdio: 'inherit' });
}
const volumesSource = 'electron/native/Volumes.swift';
const volumesBinary = 'dist-electron/native/volumes';
if (!fs.existsSync(volumesBinary) || fs.statSync(volumesSource).mtimeMs > fs.statSync(volumesBinary).mtimeMs) {
  execFileSync('xcrun', ['swiftc', '-target', 'arm64-apple-macos13.0', '-O', volumesSource, '-o', volumesBinary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', volumesBinary], { stdio: 'inherit' });
}
const archiveSource = 'electron/native/ArchiveReader.c';
const archiveBinary = 'dist-electron/native/archive-reader';
if (!fs.existsSync(archiveBinary) || Math.max(fs.statSync(archiveSource).mtimeMs, fs.statSync('scripts/build-electron.mjs').mtimeMs) > fs.statSync(archiveBinary).mtimeMs) {
  execFileSync('xcrun', ['clang', '-target', 'arm64-apple-macos13.0', '-O2', '-Wall', '-Wextra', archiveSource, '-larchive.2', '-o', archiveBinary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', archiveBinary], { stdio: 'inherit' });
}
await build({ entryPoints: ['electron/main.ts', 'electron/preload.ts'], outdir: 'dist-electron', outExtension: { '.js': '.cjs' }, bundle: true, platform: 'node', format: 'cjs', external: ['electron'], sourcemap: true });
