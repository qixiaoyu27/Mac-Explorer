import { app, BrowserWindow, ipcMain, shell, clipboard, ClipboardItem, dialog, Menu, nativeTheme, ShareMenu } from 'electron';
import fs from 'node:fs/promises';
import { watch, type FSWatcher } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { absolute, createEntry, entryFor, listDirectory, readableError, renameEntry, searchDirectory, transferEntries, moveNoReplace } from './files';
import { compressArchive, extractArchive, prepareArchiveFile, previewArchive } from './archives';
import { isArchive } from '../shared/archives';
import { FileHistory } from './history';
import { FileIcons } from './icons';
import type { Bootstrap, ClipboardInfo, OperationResult, Place, Preview, ThemeMode, Volume } from '../shared/types';

let window: BrowserWindow | null = null;
let watcher: FSWatcher | undefined;
let watchTimer: NodeJS.Timeout | undefined;
let searchController: AbortController | undefined;
const fileIcons = new FileIcons(path.join(__dirname.replace(/app\.asar(?=\/)/, 'app.asar.unpacked'), 'native/file-icon'));
const history = new FileHistory();
const isDev = process.env.EXPLORER_DEV === '1';
const testRoot = process.env.EXPLORER_TEST_ROOT;
if (testRoot) app.setPath('userData', path.join(testRoot, '.app-data'));
app.setName('Mac Explorer');

function protect(input: string) {
  const value = absolute(input);
  if (['/', '/System', '/Library', '/Applications', '/Users', os.homedir()].includes(value)) throw new Error('不能修改这个系统位置。');
  return value;
}
function pathsArg(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > 10_000) throw new Error('无效的文件选择。');
  return value.map(absolute);
}
function ipc(name: string, handler: (...args: any[]) => unknown) {
  ipcMain.handle(name, async (event, ...args) => {
    const url = event.senderFrame?.url;
    const trusted = isDev ? url?.startsWith('http://127.0.0.1:5173/') : url === pathToFileURL(path.join(__dirname, '../dist/index.html')).href;
    if (!window || event.sender !== window.webContents || !trusted) throw new Error('不受信任的请求。');
    try { return await handler(...args); }
    catch (error) { throw new Error(readableError(error)); }
  });
}
const FILE_URL_TYPE = 'electron application/osclipboard;format="public.file-url"';
const FILES_TYPE = 'electron application/osclipboard;format="local.macexplorer.files"';
async function clipboardText(item: Electron.ClipboardItem, mime: string) {
  const payload = await item.getType(mime);
  return 'text' in payload ? payload.text() : '';
}
async function getClipboard(): Promise<ClipboardInfo> {
  const items = await clipboard.read();
  const paths: string[] = [];
  for (const item of items) {
    if (item.types.includes(FILES_TYPE)) {
      try { const data = JSON.parse(await clipboardText(item, FILES_TYPE)); return { paths: pathsArg(data.paths), cut: data.cut === true }; }
      catch { /* Read native file URLs when custom data is unavailable. */ }
    }
    if (item.types.includes(FILE_URL_TYPE)) {
      try { paths.push(fileURLToPath((await clipboardText(item, FILE_URL_TYPE)).replace(/\0/g, ''))); } catch { /* Not a valid file URL. */ }
    }
  }
  if (!paths.length) for (const line of (await clipboard.readText()).split(/\r?\n/)) {
    if (line.startsWith('file://')) { try { paths.push(fileURLToPath(line)); } catch { /* Invalid URL. */ } }
  }
  return { paths, cut: false };
}
async function setClipboard(paths: string[], cut: boolean): Promise<ClipboardInfo> {
  if (!paths.length) { clipboard.clear(); return { paths, cut }; }
  await clipboard.write(paths.map((p, index) => new ClipboardItem({
    [FILE_URL_TYPE]: pathToFileURL(p).href,
    ...(index === 0 ? { 'text/plain': paths.map(p => pathToFileURL(p).href).join('\n'), [FILES_TYPE]: JSON.stringify({ paths, cut }) } : {}),
  })));
  return { paths, cut };
}
async function bootstrap(): Promise<Bootstrap> {
  const home = testRoot || os.homedir();
  const candidates: Place[] = [
    { name: '桌面', path: path.join(home, 'Desktop'), icon: 'desktop' },
    { name: '下载', path: path.join(home, 'Downloads'), icon: 'download' },
    { name: '文档', path: path.join(home, 'Documents'), icon: 'document' },
    { name: '图片', path: path.join(home, 'Pictures'), icon: 'image' },
    { name: '音乐', path: path.join(home, 'Music'), icon: 'music' },
    { name: '视频', path: path.join(home, 'Movies'), icon: 'video' },
  ];
  const places = (await Promise.all(candidates.map(async place => (await fs.stat(place.path).catch(() => null))?.isDirectory() ? place : null))).filter((p): p is Place => p !== null);
  const mounted = await fs.readdir('/Volumes').catch(() => [] as string[]);
  const volumePaths = ['/', ...mounted.filter(name => name !== 'Macintosh HD').map(name => '/Volumes/' + name)];
  const volumes: Volume[] = [];
  const seen = new Set<number>();
  for (const volumePath of volumePaths) {
    try {
      const [stat, info] = await Promise.all([fs.stat(volumePath), fs.statfs(volumePath)]);
      if (seen.has(stat.dev)) continue;
      seen.add(stat.dev);
      volumes.push({ name: volumePath === '/' ? 'Macintosh HD' : path.basename(volumePath), path: volumePath, icon: 'drive', total: info.blocks * info.bsize, free: info.bavail * info.bsize });
    } catch { /* Unmounted while enumerating. */ }
  }
  return { theme: nativeTheme.themeSource, home, places, volumes, initialPath: testRoot ? path.join(testRoot, 'Documents') : process.env.EXPLORER_START_PATH };
}
ipc('bootstrap', bootstrap);
function isThemeMode(value: unknown): value is ThemeMode { return value === 'light' || value === 'dark' || value === 'system'; }
ipc('set-theme', async (mode: unknown) => {
  if (!isThemeMode(mode)) throw new Error('无效的外观设置。');
  await fs.mkdir(app.getPath('userData'), { recursive: true });
  await fs.writeFile(path.join(app.getPath('userData'), 'appearance.json'), JSON.stringify({ theme: mode }), 'utf8');
  nativeTheme.themeSource = mode;
  window?.setBackgroundColor(nativeTheme.shouldUseDarkColors ? '#191919' : '#ffffff');
  return mode;
});
ipc('list', (input: string) => listDirectory(absolute(input)));
ipc('search', async (input: string, query: string, hidden: boolean) => {
  searchController?.abort();
  searchController = new AbortController();
  return searchDirectory(absolute(input), String(query), !!hidden, searchController.signal);
});
ipc('cancel-search', () => searchController?.abort());
ipc('info', (input: string) => entryFor(absolute(input)));
ipc('open', async (input: string) => {
  const filePath = absolute(input);
  await fs.access(filePath);
  if (isArchive(filePath) && (await fs.stat(filePath)).isFile()) return previewArchive(filePath);
  const error = await shell.openPath(filePath);
  if (error) throw new Error(error);
  return null;
});
// ponytail: one archive operation at a time; use per-destination locks if parallel jobs are needed.
let extracting = false;
app.on('before-quit', event => { if (extracting) event.preventDefault(); });
ipc('compress-archive', async (inputs: unknown) => {
  if (extracting) throw new Error('正在处理压缩包，请等待完成。');
  extracting = true;
  try { return await compressArchive(pathsArg(inputs)); }
  finally { extracting = false; }
});
ipc('open-archive-file', async (input: string, member: unknown) => {
  if (extracting) throw new Error('正在处理压缩包，请等待完成。');
  extracting = true;
  try {
    const temporary = await prepareArchiveFile(absolute(input), member);
    try {
      const error = await shell.openPath(temporary.filePath);
      if (error) throw new Error(error);
      // Keep the temporary copy after closing the preview so external editors can save it.
      // Changes are never written back into the archive.
    } catch (error) { await fs.rm(temporary.directory, { recursive: true, force: true }); throw error; }
  } finally { extracting = false; }
});
ipc('extract-archive', async (input: string, selected: unknown, mode: unknown) => {
  if (extracting) throw new Error('正在解压，请等待完成。');
  if (mode !== 'choose' && mode !== 'here' && mode !== 'folder') throw new Error('无效的解压位置。');
  const filePath = absolute(input);
  extracting = true;
  try {
    let destination = path.dirname(filePath);
    if (mode === 'choose') {
      const choice = await dialog.showOpenDialog(window!, { title: '选择解压位置', buttonLabel: '解压到此处', defaultPath: destination, properties: ['openDirectory', 'createDirectory'] });
      if (choice.canceled || !choice.filePaths.length) return null;
      destination = choice.filePaths[0];
    }
    return await extractArchive(filePath, destination, selected, mode === 'folder');
  } finally { extracting = false; }
});
ipc('reveal', (input: string) => shell.showItemInFolder(absolute(input)));
ipc('open-with', async (inputs: unknown) => {
  const paths = [...new Set(pathsArg(inputs))];
  if (!paths.length) throw new Error('请先选择要打开的文件。');
  for (const filePath of paths) {
    if (!(await fs.stat(filePath)).isFile()) throw new Error('请选择文件，然后选择打开方式。');
  }
  const choice = await dialog.showOpenDialog(window!, {
    title: '选择打开方式',
    message: paths.length === 1 ? `选择用于打开“${path.basename(paths[0])}”的应用` : `选择用于打开这 ${paths.length} 个文件的应用`,
    buttonLabel: '用此应用打开',
    defaultPath: '/Applications',
    filters: [{ name: '应用程序', extensions: ['app'] }],
    properties: ['openFile'],
  });
  if (choice.canceled || !choice.filePaths.length) return false;
  const application = absolute(choice.filePaths[0]);
  if (path.extname(application).toLowerCase() !== '.app' || !(await fs.stat(application)).isDirectory()) throw new Error('请选择有效的 Mac 应用程序（.app）。');
  await fs.access(path.join(application, 'Contents/Info.plist'));
  // Launch Services receives arguments literally; this does not alter defaults
  // and never turns filenames into shell commands.
  await promisify(execFile)('/usr/bin/open', ['-a', application, ...paths]);
  return true;
});
ipc('open-terminal', async (input: string) => {
  const directory = absolute(input);
  if (!(await fs.stat(directory)).isDirectory()) throw new Error('请选择文件夹打开终端。');
  // Pass the directory as a Launch Services document, never as shell code.
  // Terminal opens a new session at this directory without Automation access.
  await promisify(execFile)('/usr/bin/open', ['-b', 'com.apple.Terminal', directory]);
});
ipc('share', (inputs: unknown) => new ShareMenu({ filePaths: pathsArg(inputs) }).popup({ window: window! }));
ipc('quick-look', (input: string) => {
  const filePath = absolute(input);
  if (process.platform === 'darwin') window?.previewFile(filePath);
  else shell.openPath(filePath);
});
ipc('icon', (input: string, pixels = 64) => fileIcons.get(absolute(input), typeof pixels === 'number' && Number.isFinite(pixels) ? Math.min(512, Math.max(32, pixels)) : 64));
ipc('preview', async (input: string): Promise<Preview> => {
  const filePath = absolute(input);
  const entry = await entryFor(filePath);
  if (entry.isDirectory) return { kind: 'none', content: '' };
  const imageTypes: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', bmp: 'image/bmp', avif: 'image/avif' };
  if (imageTypes[entry.extension] && entry.size < 12 * 1024 * 1024) {
    return { kind: 'image', content: `data:${imageTypes[entry.extension]};base64,${(await fs.readFile(filePath)).toString('base64')}` };
  }
  if (['txt', 'md', 'json', 'js', 'jsx', 'ts', 'tsx', 'css', 'html', 'xml', 'yaml', 'yml', 'toml', 'csv', 'log', 'swift', 'py', 'go', 'rs', 'sh', 'sql', 'gitignore', ''].includes(entry.extension)) {
    const handle = await fs.open(filePath, 'r');
    try {
      const buffer = Buffer.alloc(16_384);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      if (buffer.subarray(0, bytesRead).includes(0)) return { kind: 'none', content: '' };
      return { kind: 'text', content: buffer.subarray(0, bytesRead).toString('utf8'), truncated: entry.size > bytesRead };
    } finally { await handle.close(); }
  }
  return { kind: 'none', content: '' };
});
ipc('create', async (parent: string, name: string, directory: boolean) => {
  const destination = await createEntry(absolute(parent), name, !!directory);
  await history.record('新建', [{ to: destination }]); return destination;
});
ipc('rename', async (input: string, name: string) => {
  const source = protect(input); const destination = await renameEntry(source, name);
  if (destination !== source) await history.record('重命名', [{ from: source, to: destination }]);
  return destination;
});
ipc('trash', async (inputs: unknown): Promise<OperationResult> => {
  const result: OperationResult = { succeeded: [], errors: [] };
  for (const input of pathsArg(inputs)) {
    try { await shell.trashItem(protect(input)); result.succeeded.push(input); }
    catch (error) { result.errors.push({ path: input, message: readableError(error) }); }
  }
  if (result.succeeded.length) history.clear();
  return result;
});
ipc('clipboard-set', (inputs: unknown, cut: boolean) => setClipboard(pathsArg(inputs), !!cut));
ipc('clipboard-get', getClipboard);
ipc('paste', async (parent: string) => {
  const clip = await getClipboard();
  if (clip.cut) clip.paths.forEach(protect);
  const result = await transferEntries(clip.paths, absolute(parent), clip.cut);
  await history.record(clip.cut ? '移动' : '复制', result.changes || []);
  if (clip.cut) await setClipboard(clip.paths.filter(p => !result.succeeded.includes(p)), true);
  return result;
});
ipc('copy-to', async (inputs: unknown, parent: string) => {
  const result = await transferEntries(pathsArg(inputs), absolute(parent), false);
  await history.record('复制', result.changes || []); return result;
});
ipc('history', () => history.label);
ipc('undo', () => history.undo(moveNoReplace, input => shell.trashItem(protect(input))));
ipc('copy-text', (value: string) => clipboard.writeText(String(value)));
ipc('choose-folder', async () => {
  const result = await dialog.showOpenDialog(window!, { title: '选择要打开的文件夹', properties: ['openDirectory'] });
  return result.canceled ? null : result.filePaths[0];
});
ipc('watch', (input: string | null) => {
  watcher?.close(); watcher = undefined;
  clearTimeout(watchTimer);
  if (!input) return;
  try {
    watcher = watch(absolute(input), () => {
      clearTimeout(watchTimer);
      watchTimer = setTimeout(() => window?.webContents.send('directory-changed'), 220);
    });
    watcher.on('error', () => { watcher?.close(); watcher = undefined; });
  } catch { /* Explicit refresh remains available for restricted volumes. */ }
});

function createWindow() {
  window = new BrowserWindow({
    width: 1260, height: 820, minWidth: 800, minHeight: 530, title: '文件资源管理器',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#191919' : '#ffffff', titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 18, y: 18 },
    show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true, spellcheck: false },
  });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
  window.once('ready-to-show', () => { if (!(testRoot && process.env.EXPLORER_TEST_HIDDEN === '1')) window?.show(); });
  if (isDev) window.loadURL('http://127.0.0.1:5173/');
  else window.loadFile(path.join(__dirname, '../dist/index.html'));
  window.on('close', event => { if (extracting) event.preventDefault(); });
  window.on('closed', () => { window = null; watcher?.close(); searchController?.abort(); });
}
const action = (name: string) => () => window?.webContents.send('action', name);
app.whenReady().then(async () => {
  // Set native and renderer appearance before the first window is created.
  nativeTheme.themeSource = 'light';
  try {
    const saved = JSON.parse(await fs.readFile(path.join(app.getPath('userData'), 'appearance.json'), 'utf8'));
    if (isThemeMode(saved.theme)) nativeTheme.themeSource = saved.theme;
  } catch { /* Keep the existing light appearance when no valid preference exists. */ }
  nativeTheme.on('updated', () => window?.setBackgroundColor(nativeTheme.shouldUseDarkColors ? '#191919' : '#ffffff'));
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Mac Explorer', submenu: [{ role: 'about', label: '关于 Mac Explorer' }, { type: 'separator' }, { role: 'hide', label: '隐藏' }, { role: 'quit', label: '退出' }] },
    { label: '文件', submenu: [{ label: '新建标签页', accelerator: 'Command+T', click: action('new-tab') }, { label: '打开文件夹…', click: action('choose-folder') }, { label: '新建文件夹', accelerator: 'Command+Shift+N', click: action('new-folder') }, { type: 'separator' }, { label: '关闭标签页', accelerator: 'Command+W', click: action('close-tab') }, { role: 'close', label: '关闭窗口', accelerator: 'Command+Shift+W' }] },
    { label: '编辑', submenu: [{ label: '撤销', accelerator: 'Command+Z', click: action('undo') }, { type: 'separator' }, { label: '剪切', accelerator: 'Command+X', click: action('cut') }, { label: '复制', accelerator: 'Command+C', click: action('copy') }, { label: '粘贴', accelerator: 'Command+V', click: action('paste') }, { label: '全选', accelerator: 'Command+A', click: action('select-all') }] },
    { label: '显示', submenu: [{ label: '刷新', click: action('refresh') }, { label: '显示隐藏的项目', click: action('hidden') }, { role: 'togglefullscreen', label: '进入全屏' }] },
    { label: '窗口', submenu: [{ role: 'minimize', label: '最小化' }, { role: 'zoom', label: '缩放' }, { role: 'front', label: '前置全部窗口' }] },
  ]));
  createWindow();
  app.on('activate', () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin' || testRoot) app.quit(); });
app.on('will-quit', () => fileIcons.close());
