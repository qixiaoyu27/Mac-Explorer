import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';

export class FileIcons {
  private worker?: ChildProcessWithoutNullStreams;
  private nextID = 0;
  private pending = new Map<number, { resolve: (value: string) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private cache = new Map<string, Promise<string>>();

  constructor(private executable: string) {}

  get(filePath: string, requestedPixels: number): Promise<string> {
    const pixels = [64, 128, 256, 512].find(size => size >= requestedPixels) || 512;
    const key = `${pixels}:${filePath}`;
    const cached = this.cache.get(key);
    if (cached) return cached;
    const result = new Promise<string>((resolve, reject) => {
      const worker = this.start(); const id = ++this.nextID;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('图标读取超时')); }, 30_000);
      this.pending.set(id, { resolve, reject, timer });
      worker.stdin.write(JSON.stringify({ id, path: filePath, pixels }) + '\n', error => {
        if (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
      });
    });
    if (this.cache.size >= 800) this.cache.delete(this.cache.keys().next().value!);
    this.cache.set(key, result);
    result.catch(() => { if (this.cache.get(key) === result) this.cache.delete(key); });
    return result;
  }

  private start(): ChildProcessWithoutNullStreams {
    if (this.worker) return this.worker;
    const worker = spawn(this.executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.worker = worker;
    worker.stderr.resume();
    createInterface({ input: worker.stdout }).on('line', line => {
      try {
        const response = JSON.parse(line);
        const request = this.pending.get(response.id);
        if (!request) return;
        this.pending.delete(response.id); clearTimeout(request.timer);
        if (typeof response.data === 'string' && response.data.startsWith('data:image/png;base64,')) request.resolve(response.data);
        else request.reject(new Error(response.error || '无法读取图标'));
      } catch { /* Ignore non-protocol output without accepting it as image data. */ }
    });
    const failed = () => {
      if (this.worker !== worker) return;
      this.worker = undefined;
      for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error('原生图标服务已停止')); }
      this.pending.clear();
    };
    worker.on('error', failed); worker.on('exit', failed);
    return worker;
  }

  close() { this.worker?.kill(); }
}
