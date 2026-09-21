import { t as tr } from '../shared/i18n';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { absolute, listDirectory, moveNoReplace, readableError } from './files';
import type { TrashListing, OperationResult } from '../shared/types';

export async function listTrash(roots: string[], directory?: string): Promise<TrashListing> {
  const result: TrashListing = { entries: [], roots, unavailable: [] };
  if (directory !== undefined) {
    const requested = absolute(directory);
    const root = roots.find(root => requested === root || requested.startsWith(root + path.sep));
    if (!root) throw new Error(tr('此位置不在回收站内。'));
    const [resolved, resolvedRoot] = await Promise.all([fs.realpath(requested), fs.realpath(root)]);
    if (resolved !== resolvedRoot && !resolved.startsWith(resolvedRoot + path.sep)) throw new Error(tr('无法在回收站中浏览指向外部的链接。'));
    result.entries = (await listDirectory(requested)).entries;
    return result;
  }
  for (const root of roots) {
    try { result.entries.push(...(await listDirectory(root)).entries); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') result.unavailable.push(root);
    }
  }
  return result;
}

// Identity checks stop stale restore records or confirmation snapshots acting on replacements.
export async function trashIdentity(input: string): Promise<string> {
  const stat = await fs.lstat(input);
  return `${stat.dev}:${stat.ino}:${stat.birthtimeMs}`;
}
export async function validateTrashItem(roots: string[], input: string): Promise<string> {
  const source = absolute(input);
  const root = roots.find(root => source.startsWith(root + path.sep));
  if (!root) throw new Error(tr('只能操作回收站内的项目。'));
  if ((await fs.lstat(root)).isSymbolicLink()) throw new Error(tr('回收站根目录不能是符号链接。'));
  const [parent, resolvedRoot] = await Promise.all([fs.realpath(path.dirname(source)), fs.realpath(root)]);
  if (parent !== resolvedRoot && !parent.startsWith(resolvedRoot + path.sep)) throw new Error(tr('不能操作指向回收站外部的路径。'));
  return source;
}
export interface TrashSnapshot { path: string; identity: string; parent: string }
export async function snapshotTrash(roots: string[]): Promise<TrashSnapshot[]> {
  const snapshot: TrashSnapshot[] = [];
  for (const root of roots) {
    let names: string[];
    try { names = await fs.readdir(root); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
      throw new Error(tr('部分回收站无法读取，请检查访问权限后再清空。'));
    }
    const parent = await trashIdentity(root);
    for (const name of names) {
      const input = await validateTrashItem(roots, path.join(root, name));
      snapshot.push({ path: input, identity: await trashIdentity(input), parent });
    }
  }
  return snapshot;
}
export async function emptyTrash(roots: string[], snapshot: TrashSnapshot[]): Promise<OperationResult> {
  const result: OperationResult = { succeeded: [], errors: [] };
  for (const item of snapshot) {
    try {
      const source = await validateTrashItem(roots, item.path);
      if (!roots.includes(path.dirname(source))) throw new Error(tr('只能清理回收站顶层项目。'));
      if (await trashIdentity(source) !== item.identity || await trashIdentity(path.dirname(source)) !== item.parent) throw new Error(tr('项目已发生变化，已跳过；请刷新后重试。'));
      // rm unlinks symlinks themselves; it does not traverse their targets.
      await fs.rm(source, { recursive: true });
      result.succeeded.push(source);
    } catch (error) { result.errors.push({ path: item.path, message: readableError(error) }); }
  }
  return result;
}

export class TrashOrigins {
  constructor(private directory: string) {}
  private recordPath(input: string) { return path.join(this.directory, createHash('sha256').update(input).digest('hex') + '.json'); }
  async remember(trashed: string, original: string) {
    await fs.mkdir(this.directory, { recursive: true });
    const target = this.recordPath(trashed);
    const temporary = target + '.tmp';
    await fs.writeFile(temporary, JSON.stringify({ original, identity: await trashIdentity(trashed) }), { mode: 0o600 });
    await fs.rename(temporary, target);
  }
  async original(input: string): Promise<string | null> {
    try {
      const record = JSON.parse(await fs.readFile(this.recordPath(input), 'utf8'));
      return record.identity === await trashIdentity(input) ? absolute(record.original) : null;
    } catch { return null; }
  }
  async restore(roots: string[], inputs: string[], destination?: string): Promise<OperationResult> {
    const result: OperationResult = { succeeded: [], errors: [] };
    for (const input of [...new Set(inputs)].filter(input => !inputs.some(other => other !== input && input.startsWith(other + path.sep)))) {
      try {
        const source = await validateTrashItem(roots, input);
        const original = await this.original(source);
        const target = destination ? path.join(absolute(destination), path.basename(original || source)) : original;
        if (!target) throw new Error(tr('无法确定原位置，请使用“还原到…”选择文件夹。'));
        const resolvedParent = await fs.realpath(path.dirname(target));
        for (const root of roots) {
          const resolvedRoot = await fs.realpath(root).catch(() => root);
          if (resolvedParent === resolvedRoot || resolvedParent.startsWith(resolvedRoot + path.sep)) throw new Error(tr('请选择回收站之外的还原位置。'));
        }
        await moveNoReplace(source, target);
        result.succeeded.push(source);
        await fs.unlink(this.recordPath(source)).catch(() => {});
      } catch (error) { result.errors.push({ path: input, message: readableError(error) }); }
    }
    return result;
  }
}
