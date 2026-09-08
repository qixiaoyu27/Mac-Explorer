import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { absolute, validName, listDirectory, createEntry, renameEntry, searchDirectory, transferEntries, moveNoReplace } from '../electron/files';
import { FileHistory } from '../electron/history';

async function fixture(run: (root: string) => Promise<void>) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'mac-explorer-files-'));
  try { await run(root); } finally { await fs.rm(root, { recursive: true, force: true }); }
}

test('rejects path traversal, null bytes and invalid names', () => {
  for (const name of ['', ' ', '..', '.', '../secret', 'a/b', 'a:b', 'a\0b']) assert.throws(() => validName(name));
  assert.throws(() => absolute('relative/path'));
  assert.throws(() => absolute('/tmp/bad\0path'));
  assert.equal(validName('旅行计划 2026.md'), '旅行计划 2026.md');
});
test('lists real metadata, hidden files, directories and dangling symlinks', () => fixture(async root => {
  await fs.writeFile(path.join(root, '笔记.txt'), 'hello');
  await fs.writeFile(path.join(root, '.hidden'), 'hidden');
  await fs.mkdir(path.join(root, '文件夹'));
  await fs.symlink('/nonexistent-explorer-test', path.join(root, 'broken'));
  const { entries } = await listDirectory(root);
  assert.equal(entries.length, 4);
  assert.equal(entries.find(e => e.name === '笔记.txt')?.size, 5);
  assert.equal(entries.find(e => e.name === '.hidden')?.hidden, true);
  assert.equal(entries.find(e => e.name === '文件夹')?.isDirectory, true);
  assert.equal(entries.find(e => e.name === 'broken')?.isSymlink, true);
}));
test('create and rename never overwrite existing content', () => fixture(async root => {
  const created = await createEntry(root, '新建.txt', false);
  await fs.writeFile(created, 'original');
  await assert.rejects(createEntry(root, '新建.txt', false));
  await fs.writeFile(path.join(root, '已存在.txt'), 'precious');
  await assert.rejects(renameEntry(created, '已存在.txt'));
  assert.equal(await fs.readFile(path.join(root, '已存在.txt'), 'utf8'), 'precious');
  const renamed = await renameEntry(created, '已改名.txt');
  assert.equal(await fs.readFile(renamed, 'utf8'), 'original');
  await assert.rejects(fs.access(created));
}));
test('copy keeps the source and preserves nested content', () => fixture(async root => {
  const source = await createEntry(root, 'source', true);
  const target = await createEntry(root, 'target', true);
  await fs.mkdir(path.join(source, 'child'));
  await fs.writeFile(path.join(source, 'child', 'notes.txt'), 'nested data');
  const result = await transferEntries([source], target, false);
  assert.equal(result.errors.length, 0);
  assert.equal(await fs.readFile(path.join(target, 'source', 'child', 'notes.txt'), 'utf8'), 'nested data');
  assert.equal(await fs.readFile(path.join(source, 'child', 'notes.txt'), 'utf8'), 'nested data');
}));
test('pasting in the same folder produces unique copies', () => fixture(async root => {
  const source = await createEntry(root, '报告.txt', false);
  await fs.writeFile(source, 'report');
  await transferEntries([source], root, false);
  await transferEntries([source], root, false);
  assert.equal(await fs.readFile(path.join(root, '报告 - 副本.txt'), 'utf8'), 'report');
  assert.equal(await fs.readFile(path.join(root, '报告 - 副本 (2).txt'), 'utf8'), 'report');
}));
test('batch transfer reports partial failure without overwriting', () => fixture(async root => {
  const target = await createEntry(root, 'target', true);
  const first = await createEntry(root, 'first.txt', false);
  const second = await createEntry(root, 'second.txt', false);
  await fs.writeFile(path.join(target, 'first.txt'), 'keep');
  const result = await transferEntries([first, second], target, false);
  assert.equal(result.succeeded.length, 1);
  assert.equal(result.errors.length, 1);
  assert.equal(await fs.readFile(path.join(target, 'first.txt'), 'utf8'), 'keep');
  await fs.access(path.join(target, 'second.txt'));
}));
test('cut moves files and cut into the same parent is a no-op', () => fixture(async root => {
  const source = await createEntry(root, 'move me.txt', false);
  await fs.writeFile(source, 'content');
  const noop = await transferEntries([source], root, true);
  assert.equal(noop.errors.length, 0);
  await fs.access(source);
  const target = await createEntry(root, 'target', true);
  const result = await transferEntries([source], target, true);
  assert.equal(result.errors.length, 0);
  await assert.rejects(fs.access(source));
  assert.equal(await fs.readFile(path.join(target, 'move me.txt'), 'utf8'), 'content');
}));
test('cut collisions leave both files unchanged', () => fixture(async root => {
  const source = await createEntry(root, 'same.txt', false);
  await fs.writeFile(source, 'source');
  const target = await createEntry(root, 'target', true);
  await fs.writeFile(path.join(target, 'same.txt'), 'destination');
  const result = await transferEntries([source], target, true);
  assert.equal(result.errors.length, 1);
  assert.equal(await fs.readFile(source, 'utf8'), 'source');
  assert.equal(await fs.readFile(path.join(target, 'same.txt'), 'utf8'), 'destination');
}));
test('rejects copying into a descendant including through a symlink', () => fixture(async root => {
  const source = await createEntry(root, 'source', true);
  const descendant = await createEntry(source, 'child', true);
  const alias = path.join(root, 'alias'); await fs.symlink(descendant, alias);
  for (const destination of [source, descendant, alias]) {
    const result = await transferEntries([source], destination, false);
    assert.equal(result.errors.length, 1);
    assert.equal(result.succeeded.length, 0);
  }
}));
test('copies symbolic links without following them', () => fixture(async root => {
  const original = await createEntry(root, 'original.txt', false);
  const link = path.join(root, 'linked.txt'); await fs.symlink(original, link);
  const target = await createEntry(root, 'target', true);
  const result = await transferEntries([link], target, false);
  assert.equal(result.errors.length, 0);
  assert.equal((await fs.lstat(path.join(target, 'linked.txt'))).isSymbolicLink(), true);
  assert.equal(await fs.readlink(path.join(target, 'linked.txt')), original);
}));
test('search finds nested names, honors hidden filtering and avoids symlink loops', () => fixture(async root => {
  await fs.mkdir(path.join(root, 'nested'));
  await fs.writeFile(path.join(root, 'nested', 'Report.md'), '');
  await fs.writeFile(path.join(root, '.Report'), '');
  await fs.symlink(root, path.join(root, 'nested', 'cycle'));
  const visible = await searchDirectory(root, 'report', false);
  assert.equal(visible.entries.length, 1);
  assert.equal(visible.truncated, false);
  const all = await searchDirectory(root, 'report', true);
  assert.equal(all.entries.length, 2);
}));
test('search cancellation stops traversal', () => fixture(async root => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(searchDirectory(root, 'x', false, controller.signal), /取消/);
}));
test('supports case-only renames on the Mac filesystem', () => fixture(async root => {
  const file = await createEntry(root, 'README.md', false);
  await fs.writeFile(file, 'case');
  await renameEntry(file, 'readme.md');
  assert.deepEqual(await fs.readdir(root), ['readme.md']);
  assert.equal(await fs.readFile(path.join(root, 'readme.md'), 'utf8'), 'case');
}));
test('undo reverses a move without overwriting an existing original path', () => fixture(async root => {
  const history = new FileHistory();
  const original = await createEntry(root, 'original.txt', false);
  await fs.writeFile(original, 'content');
  const renamed = await renameEntry(original, 'renamed.txt');
  await history.record('重命名', [{ from: original, to: renamed }]);
  await fs.writeFile(original, 'other file');
  const conflict = await history.undo(moveNoReplace, async () => { throw new Error('must not trash'); });
  assert.equal(conflict.errors.length, 1);
  assert.equal(await fs.readFile(original, 'utf8'), 'other file');
  await fs.unlink(original);
  const result = await history.undo(moveNoReplace, async () => { throw new Error('must not trash'); });
  assert.equal(result.errors.length, 0);
  assert.equal(await fs.readFile(original, 'utf8'), 'content');
  assert.equal(history.label, null);
}));
test('undo refuses to discard a newly created file that was subsequently edited', () => fixture(async root => {
  const history = new FileHistory(); const file = await createEntry(root, 'new.txt', false);
  await history.record('新建', [{ to: file }]);
  await fs.writeFile(file, 'user changes');
  let trashed = false;
  const result = await history.undo(moveNoReplace, async () => { trashed = true; });
  assert.equal(result.errors.length, 1); assert.equal(trashed, false);
  assert.equal(await fs.readFile(file, 'utf8'), 'user changes');
}));
