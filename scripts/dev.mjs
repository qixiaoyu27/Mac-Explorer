import { spawn } from 'node:child_process';
import { createServer } from 'vite';
import './build-electron.mjs';
const server = await createServer();
await server.listen();
const child = spawn('node_modules/.bin/electron', ['.'], { stdio: 'inherit', env: { ...process.env, EXPLORER_DEV: '1' } });
const stop = async () => { child.kill(); await server.close(); process.exit(); };
child.on('exit', stop);
process.on('SIGINT', stop);
