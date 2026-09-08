import fs from 'node:fs/promises';
import type { FileChange, OperationResult } from '../shared/types';
import { readableError } from './files';

type Step = FileChange & { inode: number; device: number; modified: number; size: number };
export class FileHistory {
  private stack: { label: string; steps: Step[] }[] = [];
  get label(): string | null { return this.stack.at(-1)?.label || null; }
  clear() { this.stack = []; }
  async record(label: string, changes: FileChange[]) {
    if (!changes.length) return;
    const steps: Step[] = [];
    for (const change of changes) {
      const stat = await fs.lstat(change.to).catch(() => null);
      if (stat) steps.push({ ...change, inode: stat.ino, device: stat.dev, modified: stat.mtimeMs, size: stat.size });
    }
    if (steps.length) this.stack.push({ label, steps: steps.reverse() });
    this.stack = this.stack.slice(-30);
  }
  async undo(move: (from: string, to: string) => Promise<void>, trash: (path: string) => Promise<void>): Promise<OperationResult> {
    const batch = this.stack.at(-1);
    const result: OperationResult = { succeeded: [], errors: [] };
    if (!batch) return result;
    const remaining: Step[] = [];
    for (const step of batch.steps) {
      try {
        const current = await fs.lstat(step.to);
        if (current.ino !== step.inode || current.dev !== step.device) throw new Error('项目已被其他文件替换，无法撤销。');
        if (step.from) await move(step.to, step.from);
        else {
          if (current.mtimeMs !== step.modified || current.size !== step.size) throw new Error('项目在操作后已被修改，为保留改动，无法自动撤销。');
          await trash(step.to);
        }
        result.succeeded.push(step.to);
      } catch (error) { remaining.push(step); result.errors.push({ path: step.to, message: readableError(error) }); }
    }
    if (remaining.length) batch.steps = remaining;
    else this.stack.pop();
    return result;
  }
}
