import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

fs.mkdirSync('dist-electron/native', { recursive: true });
const source = 'electron/native/FileIcon.swift';
const binary = 'dist-electron/native/file-icon';
if (!fs.existsSync(binary) || Math.max(fs.statSync(source).mtimeMs, fs.statSync('scripts/build-electron.mjs').mtimeMs) > fs.statSync(binary).mtimeMs) {
  execFileSync('xcrun', ['swiftc', '-target', 'arm64-apple-macos13.0', '-O', source, '-o', binary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', binary], { stdio: 'inherit' });
}
const archiveSource = 'electron/native/ArchiveReader.c';
const archiveBinary = 'dist-electron/native/archive-reader';
if (!fs.existsSync(archiveBinary) || Math.max(fs.statSync(archiveSource).mtimeMs, fs.statSync('scripts/build-electron.mjs').mtimeMs) > fs.statSync(archiveBinary).mtimeMs) {
  execFileSync('xcrun', ['clang', '-target', 'arm64-apple-macos13.0', '-O2', '-Wall', '-Wextra', archiveSource, '-larchive.2', '-o', archiveBinary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', archiveBinary], { stdio: 'inherit' });
}
await build({ entryPoints: ['electron/main.ts', 'electron/preload.ts'], outdir: 'dist-electron', outExtension: { '.js': '.cjs' }, bundle: true, platform: 'node', format: 'cjs', external: ['electron'], sourcemap: true });
