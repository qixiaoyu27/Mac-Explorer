import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import type { ArchivePreview, OperationResult } from '../shared/types';
import { archiveFolderName, isArchive } from '../shared/archives';
import { absolute, readableError, validName } from './files';

const reader = path.join(__dirname.replace(/app\.asar(?=\/)/, 'app.asar.unpacked'), 'native/archive-reader');
async function native(args: string[], timeout = 15_000) {
  try {
    return (await promisify(execFile)(reader, args, { encoding: 'utf8', timeout, maxBuffer: 4 * 1024 * 1024 })).stdout;
  } catch (error) {
    const e = error as Error & { stderr?: string; killed?: boolean; code?: string };
    if (e.killed || e.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') throw new Error('压缩包超过读取限制或操作超时。');
    throw new Error(e.stderr?.trim() || readableError(error));
  }
}
export async function previewArchive(input: string): Promise<ArchivePreview> {
  const filePath = absolute(input);
  if (!isArchive(filePath) || !(await fs.stat(filePath)).isFile()) throw new Error('请选择压缩文件。');
  try {
    const output = await native(['list', filePath]);
    return { path: filePath, name: path.basename(filePath), entries: output.split('\n').filter(Boolean).map(line => JSON.parse(line)) };
  } catch (error) { throw new Error(`无法预览此压缩包：${readableError(error)}`); }
}
export async function extractArchive(input: string, destination: string, selected: unknown, namedFolder: boolean): Promise<OperationResult> {
  const archive = await previewArchive(input);
  if (selected !== null && (!Array.isArray(selected) || !selected.length || selected.length > 10_000 || selected.some(p => typeof p !== 'string' || !p || p.includes('\0') || !archive.entries.some(e => e.path === p || e.path.startsWith(p + '/'))))) throw new Error('无效的压缩包项目选择，请重新打开预览。');
  const target = await fs.realpath(absolute(destination));
  if (!(await fs.stat(target)).isDirectory()) throw new Error('请选择解压目标文件夹。');
  const result: OperationResult = { succeeded: [], errors: [] };
  const staging = await fs.mkdtemp(path.join(target, '.explorer-extract-'));
  try {
    // Stage everything first; corrupt archives never publish partially decoded data.
    await native(['extract', archive.path, staging, ...(selected as string[] | null || [])], 300_000);
    const names = namedFolder ? [validName(archiveFolderName(archive.name))] : await fs.readdir(staging);
    for (const name of names) {
      const output = path.join(target, name);
      try {
        await native(['publish', namedFolder ? staging : path.join(staging, name), output]);
        result.succeeded.push(output);
      } catch (error) {
        const exists = await fs.lstat(output).then(() => true, () => false);
        result.errors.push({ path: output, message: exists ? '同名项目已存在，已跳过并保留原内容。' : readableError(error) });
      }
    }
    return result;
  } finally { await fs.rm(staging, { recursive: true, force: true }); }
}

export async function prepareArchiveFile(input: string, member: unknown) {
  const archive = await previewArchive(input);
  if (typeof member !== 'string' || !archive.entries.some(entry => entry.path === member && !entry.directory)) throw new Error('请选择压缩包内的文件。');
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'mac-explorer-open-'));
  try {
    await native(['extract', archive.path, directory, member], 300_000);
    const filePath = path.join(directory, member);
    if (!(await fs.lstat(filePath)).isFile()) throw new Error('无法打开此压缩包项目。');
    // Retain the source archive's macOS quarantine checks when opening its contents.
    await native(['quarantine', archive.path, filePath]);
    return { directory, filePath };
  } catch (error) { await fs.rm(directory, { recursive: true, force: true }); throw error; }
}

export async function compressArchive(inputs: string[]): Promise<string> {
  if (!inputs.length || inputs.length > 10_000) throw new Error('请先选择要压缩的文件或文件夹。');
  const candidates = [...new Set(inputs.map(absolute))];
  const sources = candidates.filter(p => !candidates.some(other => other !== p && p.startsWith(other + path.sep)));
  for (const source of sources) {
    if (source === path.parse(source).root) throw new Error('不能压缩整个磁盘。');
    const stat = await fs.lstat(source);
    if (!stat.isFile() && !stat.isDirectory()) throw new Error('暂不支持压缩链接或特殊文件。');
  }
  let baseDirectory = path.dirname(sources[0]);
  while (sources.some(p => !p.startsWith(baseDirectory === '/' ? '/' : baseDirectory + path.sep))) baseDirectory = path.dirname(baseDirectory);
  const parent = await fs.realpath(baseDirectory);
  const singleDirectory = sources.length === 1 && (await fs.stat(sources[0])).isDirectory();
  const stem = sources.length === 1 ? singleDirectory ? path.basename(sources[0]) : path.parse(sources[0]).name : '压缩文件';
  validName(stem + '.zip');
  const staging = await fs.mkdtemp(path.join(parent, '.explorer-compress-'));
  const archivePath = path.join(staging, 'output.zip');
  try {
    const { stderr } = await promisify(execFile)('/usr/bin/tar', ['-c', '--format', 'zip', '--no-mac-metadata', '-f', archivePath, '-C', baseDirectory, ...sources.map(p => './' + path.relative(baseDirectory, p))], { encoding: 'utf8', timeout: 300_000, maxBuffer: 1024 * 1024 });
    if (stderr.trim()) throw new Error(`压缩未完成：${stderr.trim()}`);
    // Check the same format/path/link limits as our preview before publishing.
    await previewArchive(archivePath);
    await fs.chmod(archivePath, 0o600);
    for (let index = 1; index <= 10_000; index++) {
      const output = path.join(parent, validName(`${stem}${index === 1 ? '' : ` (${index})`}.zip`));
      try { await native(['publish', archivePath, output]); return output; }
      catch (error) { if (!(await fs.lstat(output).then(() => true, () => false))) throw error; }
    }
    throw new Error('同名压缩包过多，请先重命名部分文件。');
  } finally { await fs.rm(staging, { recursive: true, force: true }); }
}
