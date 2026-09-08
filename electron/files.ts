import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { FileEntry, Listing, OperationResult, SearchResult } from '../shared/types';

const exec = promisify(execFile);
export function absolute(value: unknown): string {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) throw new Error('需要有效的绝对路径。');
  return path.normalize(value);
}
export function validName(value: unknown): string {
  if (typeof value !== 'string' || !value.trim() || value === '.' || value === '..' || /[/\0:]/.test(value)) {
    throw new Error('名称不能为空，也不能包含 /、: 或空字符。');
  }
  if (Buffer.byteLength(value) > 255) throw new Error('名称过长，请使用更短的名称。');
  return value;
}
export function readableError(error: unknown): string {
  const e = error as NodeJS.ErrnoException;
  if (e.code === 'EACCES' || e.code === 'EPERM') return '没有访问权限。请在系统设置 → 隐私与安全性中允许访问该文件夹。';
  if (e.code === 'ENOENT') return '文件或文件夹已不存在，请刷新后重试。';
  if (e.code === 'EEXIST' || e.code === 'ERR_FS_CP_EEXIST') return '已存在同名项目。请更改名称后重试，现有文件不会被覆盖。';
  if (e.code === 'ENOSPC') return '磁盘空间不足，请释放空间后重试。';
  if (e.code === 'EROFS') return '此位置是只读的，无法修改。';
  return e.message || String(error);
}
export async function entryFor(input: string): Promise<FileEntry> {
  const filePath = absolute(input);
  const stat = await fs.lstat(filePath);
  const target = stat.isSymbolicLink() ? await fs.stat(filePath).catch(() => stat) : stat;
  const name = path.basename(filePath) || '/';
  return {
    path: filePath, name, isDirectory: target.isDirectory(), isSymlink: stat.isSymbolicLink(),
    size: target.size, modified: target.mtimeMs, created: target.birthtimeMs,
    extension: target.isDirectory() ? '' : path.extname(name).slice(1).toLowerCase(), hidden: name.startsWith('.'),
  };
}
export async function listDirectory(input: string): Promise<Listing> {
  const directory = absolute(input);
  const children = await fs.readdir(directory);
  const entries: FileEntry[] = [];
  // Bound metadata reads so large directories do not exhaust descriptors.
  for (let index = 0; index < children.length; index += 64) {
    const batch = await Promise.all(children.slice(index, index + 64).map(name => entryFor(path.join(directory, name)).catch(() => null)));
    entries.push(...batch.filter((entry): entry is FileEntry => entry !== null));
  }
  return { path: directory, entries };
}
export async function searchDirectory(input: string, query: string, hidden: boolean, signal?: AbortSignal): Promise<SearchResult> {
  const queue = [absolute(input)];
  const entries: FileEntry[] = [];
  const needle = query.trim().toLocaleLowerCase();
  let visited = 0; let skipped = 0;
  if (!needle) return { entries, truncated: false, skipped };
  while (queue.length && visited < 30_000 && entries.length < 1_000) {
    if (signal?.aborted) throw new Error('搜索已取消。');
    const current = queue.shift()!;
    const children = await fs.readdir(current, { withFileTypes: true }).catch(error => {
      if (current === absolute(input)) throw error;
      skipped++; return [];
    });
    for (const child of children) {
      if (signal?.aborted) throw new Error('搜索已取消。');
      if (!hidden && child.name.startsWith('.')) continue;
      visited++;
      const childPath = path.join(current, child.name);
      if (child.name.toLocaleLowerCase().includes(needle)) {
        const entry = await entryFor(childPath).catch(() => null);
        if (entry) entries.push(entry);
      }
      // Never recurse through symlinks or app bundles; both can escape the expected tree.
      if (child.isDirectory() && !child.name.endsWith('.app')) queue.push(childPath);
      if (visited >= 30_000 || entries.length >= 1_000) return { entries, truncated: true, skipped };
    }
  }
  return { entries, truncated: queue.length > 0, skipped };
}
async function ensureAbsent(destination: string) {
  try { await fs.lstat(destination); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return;
    throw error;
  }
  throw Object.assign(new Error('已存在同名项目。'), { code: 'EEXIST' });
}
export async function createEntry(parent: string, name: string, directory: boolean): Promise<string> {
  const destination = path.join(absolute(parent), validName(name));
  if (directory) await fs.mkdir(destination);
  else await fs.writeFile(destination, '', { flag: 'wx' });
  return destination;
}
export async function moveNoReplace(source: string, destination: string) {
  await ensureAbsent(destination);
  // macOS mv -n handles cross-volume moves and refuses to replace existing items.
  await exec('/bin/mv', ['-n', source, destination]);
  const remains = await fs.lstat(source).then(() => true, error => {
    if (error.code === 'ENOENT') return false;
    throw error;
  });
  if (remains) throw new Error('移动未完成，目标可能已存在同名项目。原文件已保留。');
}
export async function renameEntry(input: string, name: string): Promise<string> {
  const source = absolute(input);
  if (source === '/') throw new Error('不能重命名根目录。');
  const destination = path.join(path.dirname(source), validName(name));
  if (source === destination) return source;
  // APFS is usually case-insensitive. A temporary hop allows case-only renames
  // without treating the original file as a conflicting destination.
  if (source.normalize('NFC').toLocaleLowerCase() === destination.normalize('NFC').toLocaleLowerCase()) {
    const [original, target] = await Promise.all([fs.lstat(source), fs.lstat(destination).catch(() => null)]);
    if (target && original.ino === target.ino && original.dev === target.dev) {
      const temporary = path.join(path.dirname(source), `.explorer-rename-${crypto.randomUUID()}`);
      await moveNoReplace(source, temporary);
      try { await moveNoReplace(temporary, destination); }
      catch (error) { await moveNoReplace(temporary, source); throw error; }
      return destination;
    }
  }
  await moveNoReplace(source, destination);
  return destination;
}
export async function transferEntries(inputs: string[], parent: string, cut: boolean): Promise<OperationResult> {
  const directory = await fs.realpath(absolute(parent));
  if (!(await fs.stat(directory)).isDirectory()) throw new Error('目标必须是文件夹。');
  const result: OperationResult = { succeeded: [], errors: [], changes: [] };
  for (const input of [...new Set(inputs)]) {
    const source = absolute(input);
    try {
      if (source === '/') throw new Error('不能复制或移动根目录。');
      const realSource = await fs.realpath(source);
      const stat = await fs.lstat(source);
      if (stat.isDirectory() && (directory === realSource || directory.startsWith(realSource + path.sep))) {
        throw new Error('不能将文件夹放入它自身或它的子文件夹。');
      }
      let destination = path.join(directory, path.basename(source));
      const sourceParent = await fs.realpath(path.dirname(source));
      if (sourceParent === directory) {
        if (cut) { result.succeeded.push(source); continue; }
        const ext = stat.isDirectory() ? '' : path.extname(source);
        const stem = path.basename(source, ext);
        let number = 1;
        do {
          destination = path.join(directory, `${stem} - 副本${number === 1 ? '' : ` (${number})`}${ext}`);
          number++;
        } while (await fs.lstat(destination).then(() => true, () => false));
      }
      await ensureAbsent(destination);
      if (cut) await moveNoReplace(source, destination);
      else await fs.cp(source, destination, { recursive: true, force: false, errorOnExist: true, verbatimSymlinks: true, preserveTimestamps: true });
      result.succeeded.push(source);
      result.changes!.push({ from: cut ? source : undefined, to: destination });
    } catch (error) { result.errors.push({ path: source, message: readableError(error) }); }
  }
  return result;
}
