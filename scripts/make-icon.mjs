import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
fs.mkdirSync('build/icon.iconset', { recursive: true });
fs.copyFileSync('design/icon-selected-mirrored.png', 'build/icon-1024.png');
for (const size of [16, 32, 128, 256, 512]) {
  execFileSync('sips', ['-z', String(size), String(size), 'build/icon-1024.png', '--out', `build/icon.iconset/icon_${size}x${size}.png`], { stdio: 'ignore' });
  execFileSync('sips', ['-z', String(size * 2), String(size * 2), 'build/icon-1024.png', '--out', `build/icon.iconset/icon_${size}x${size}@2x.png`], { stdio: 'ignore' });
}
execFileSync('iconutil', ['-c', 'icns', 'build/icon.iconset', '-o', 'build/icon.icns']);
console.log('Created build/icon.icns');
