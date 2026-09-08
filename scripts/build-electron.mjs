import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

fs.mkdirSync('dist-electron/native', { recursive: true });
const source = 'electron/native/FileIcon.swift';
const binary = 'dist-electron/native/file-icon';
if (!fs.existsSync(binary) || fs.statSync(source).mtimeMs > fs.statSync(binary).mtimeMs) {
  execFileSync('xcrun', ['swiftc', '-O', source, '-o', binary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', binary], { stdio: 'inherit' });
}
const archiveSource = 'electron/native/ArchiveReader.c';
const archiveBinary = 'dist-electron/native/archive-reader';
if (!fs.existsSync(archiveBinary) || fs.statSync(archiveSource).mtimeMs > fs.statSync(archiveBinary).mtimeMs) {
  execFileSync('xcrun', ['clang', '-O2', '-Wall', '-Wextra', archiveSource, '-larchive.2', '-o', archiveBinary], { stdio: 'inherit' });
  execFileSync('codesign', ['--force', '--sign', '-', archiveBinary], { stdio: 'inherit' });
}
await build({ entryPoints: ['electron/main.ts', 'electron/preload.ts'], outdir: 'dist-electron', outExtension: { '.js': '.cjs' }, bundle: true, platform: 'node', format: 'cjs', external: ['electron'], sourcemap: true });
