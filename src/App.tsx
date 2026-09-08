import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type MouseEvent, type ReactNode } from 'react';
import {
  Archive, ArrowLeft, ArrowRight, ArrowUp, ArrowDownWideNarrow, Check, ChevronDown, ChevronRight,
  ClipboardPaste, Copy, Download, ExternalLink, FilePlus2, FileText, Film, FolderOpen,
  FolderPlus, HardDrive, Home, Image, Info, Keyboard, LayoutGrid, List, Loader2,
  PanelLeft, Eye, FileType, SquareCheck, ChevronsDownUp,
  Monitor, MoreHorizontal, Music2, PanelRight, Pin, Plus, RotateCw, Scissors,
  Search, Share2, Star, Sun, Moon, SunMoon, Terminal, TextCursorInput, Trash2, Undo2, X,
} from 'lucide-react';
import { createPortal } from 'react-dom';
import { archiveFolderName, isArchive } from '../shared/archives';
import type { ExtractMode, ArchivePreview, Bootstrap, ClipboardInfo, FileEntry, OperationResult, Place, Preview, ThemeMode } from '../shared/types';

const api = window.explorer;
const HOME = 'home'; const PC = 'computer';
type Tab = { id: string; location: string; history: string[]; index: number };
type SortKey = 'name' | 'modified' | 'type' | 'size';
type View = 'details' | 'icons' | 'list' | 'tiles' | 'content';
type MenuItem = { children?: MenuItem[]; radio?: boolean; label: string; icon?: ReactNode; action?: () => void; shortcut?: string; checked?: boolean; disabled?: boolean; danger?: boolean; divider?: boolean };
type Popup = { x: number; y: number; items: MenuItem[]; quickActions?: MenuItem[] };
type Modal = { kind: 'archive'; archive: ArchivePreview } | { kind: 'folder' | 'file' | 'rename'; path: string; name: string } | { kind: 'trash'; paths: string[] } | { kind: 'shortcuts' };
const makeTab = (location = HOME): Tab => ({ id: crypto.randomUUID(), location, history: [location], index: 0 });
function stored<T,>(key: string, fallback: T): T { try { return JSON.parse(localStorage.getItem(key) || 'null') ?? fallback; } catch { return fallback; } }
function base(path: string) { return path.split('/').filter(Boolean).at(-1) || 'Macintosh HD'; }
function parent(path: string) { return path.slice(0, path.lastIndexOf('/')) || '/'; }
function join(path: string, name: string) { return `${path === '/' ? '' : path}/${name}`; }
function isVirtual(location: string) { return location === HOME || location === PC; }
function size(bytes: number) { return new Intl.NumberFormat('zh-CN', { maximumFractionDigits: bytes >= 1e9 ? 1 : 0 }).format(bytes / (bytes >= 1024 ** 3 ? 1024 ** 3 : bytes >= 1024 ** 2 ? 1024 ** 2 : bytes >= 1024 ? 1024 : 1)) + ' ' + (bytes >= 1024 ** 3 ? 'GB' : bytes >= 1024 ** 2 ? 'MB' : bytes >= 1024 ? 'KB' : '字节'); }
function date(value: number) { return new Date(value).toLocaleString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }); }
function type(entry: FileEntry) {
  if (entry.isDirectory) return entry.name.endsWith('.app') ? '应用程序' : entry.isSymlink ? '文件夹链接' : '文件夹';
  const names: Record<string, string> = { pdf: 'PDF 文档', txt: '文本文档', md: 'Markdown 文档', png: 'PNG 图像', jpg: 'JPEG 图像', jpeg: 'JPEG 图像', heic: 'HEIC 图像', zip: 'ZIP 压缩文件', dmg: '磁盘映像', mp4: 'MP4 视频', mov: 'QuickTime 视频', mp3: 'MP3 音频', docx: 'Word 文档', xlsx: 'Excel 工作簿', pptx: 'PowerPoint 演示文稿' };
  return names[entry.extension] || (entry.extension ? `${entry.extension.toUpperCase()} 文件` : '文件');
}
function errorMessage(error: unknown) { return String(error instanceof Error ? error.message : error).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''); }

function PlaceIcon({ icon, size: dimension = 18 }: { icon: string; size?: number }) {
  const Component = ({ home: Home, star: Star, desktop: Monitor, download: Download, document: FileText, image: Image, music: Music2, video: Film, drive: HardDrive, folder: FolderOpen, computer: Monitor } as Record<string, typeof Home>)[icon] || FolderOpen;
  return <Component size={dimension} strokeWidth={1.6} className={`place-icon icon-${icon}`} aria-hidden="true" />;
}
function ViewGlyph({ mode }: { mode: 'extra' | 'large' | 'medium' | 'small' | 'list' | 'details' | 'tiles' | 'content' }) {
  return <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden="true">
    {mode === 'extra' ? <><rect x="2" y="2" width="15" height="13" rx="1.5"/><path d="M4 18h11"/></> : mode === 'large' ? <><rect x="4" y="3" width="12" height="11" rx="1.5"/><path d="M4 17h12"/></> : mode === 'medium' ? <><rect x="6" y="2" width="8" height="8" rx="1"/><path d="M5 13h10M6 16h8"/></> : mode === 'small' ? <>{[3, 11].flatMap(x => [3, 11].map(y => <rect key={`${x}-${y}`} x={x} y={y} width="5" height="5" rx="1"/>))}</> : mode === 'list' ? <path d="M2 4h6m4 0h6M2 8h6m4 0h6M2 12h6m4 0h6M2 16h6m4 0h6"/> : mode === 'details' ? <path d="M2 4h16M2 8h16M2 12h16M2 16h16"/> : <>{(mode === 'tiles' ? [3, 12] : [2, 8, 14]).map(y => <g key={y}><rect x="2" y={y} width="4" height="4" rx="1"/><path d={`M10 ${y + 1}h8M10 ${y + 4}h5`}/></g>)}</>}
  </svg>;
}
function FolderGlyph({ dimension = 38, badge }: { dimension?: number; badge?: string }) {
  return <span className="folder-glyph" style={{ width: dimension, height: dimension }} aria-hidden="true">
    <svg viewBox="0 0 48 44" fill="none"><path d="M3 10a3 3 0 0 1 3-3h12l5 5h19a3 3 0 0 1 3 3v23H3V10Z" fill="#d79b20"/><path d="M3 16h42v20a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V16Z" fill="#ffcb4c"/><path d="M3 16h42v4H3z" fill="#ffdb71"/><path d="M6 39h36" stroke="#dfa629" strokeWidth="1"/></svg>
    {badge && <span className={`folder-badge badge-${badge}`}><PlaceIcon icon={badge} size={dimension > 45 ? 20 : 14}/></span>}
  </span>;
}
function FileGlyph({ entry, dimension = 22 }: { entry: FileEntry; dimension?: number }) {
  const [icon, setIcon] = useState('');
  const pixels = Math.min(512, Math.max(64, 2 ** Math.ceil(Math.log2(dimension * window.devicePixelRatio))));
  useEffect(() => {
    let live = true;
    if (!entry.isDirectory || entry.name.endsWith('.app')) api.icon(entry.path, pixels).then(value => { if (live) setIcon(value); }).catch(() => {});
    return () => { live = false; };
  }, [entry.path, entry.isDirectory, entry.name, pixels]);
  if (entry.isDirectory && !entry.name.endsWith('.app')) return <FolderGlyph dimension={dimension} />;
  const style = { width: dimension, height: dimension };
  return icon ? <img className="file-glyph" style={style} src={icon} alt="" draggable={false}/> : <FileText className="file-glyph" style={style} strokeWidth={1.2}/>;
}
function ToolButton({ label, children, onClick, disabled = false, active = false, className = '' }: { label: string; children: ReactNode; onClick: (event: MouseEvent<HTMLButtonElement>) => void; disabled?: boolean; active?: boolean; className?: string }) {
  return <button className={`tool-button ${active ? 'active' : ''} ${className}`} title={label} aria-label={label} disabled={disabled} onClick={onClick}>{children}</button>;
}

export default function App() {
  const [theme, setTheme] = useState<ThemeMode>('light');
  const [boot, setBoot] = useState<Bootstrap | null>(null);
  const [tabs, setTabs] = useState<Tab[]>([makeTab()]);
  const [activeID, setActiveID] = useState('');
  const tab = tabs.find(t => t.id === activeID) || tabs[0];
  const location = tab.location;
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const selectionAnchor = useRef<string | null>(null);
  const [view, setView] = useState<View>(() => stored('view', 'details'));
  const [iconSize, setIconSize] = useState(() => { const value = stored<number>('iconSize', 64); return typeof value === 'number' && Number.isFinite(value) ? Math.min(128, Math.max(32, Math.round(value / 8) * 8)) : 64; });
  const [sort, setSort] = useState<SortKey>(() => stored('sort', 'name'));
  const [ascending, setAscending] = useState(() => stored('ascending', true));
  const [hidden, setHidden] = useState(() => stored('hidden', false));
  const [extensions, setExtensions] = useState(() => stored('extensions', true));
  const [details, setDetails] = useState(() => stored('details', false));
  const [previewPane, setPreviewPane] = useState(() => !stored('details', false) && stored('previewPane', false));
  const [navigationPane, setNavigationPane] = useState(() => stored('navigationPane', true));
  const [compact, setCompact] = useState(() => stored('compact', false));
  const [checkboxes, setCheckboxes] = useState(() => stored('checkboxes', false));
  const [pins, setPins] = useState<string[]>(() => stored('pins', []));
  const [unpinnedDefaults, setUnpinnedDefaults] = useState<string[]>(() => stored('unpinnedDefaults', []));
  const [recent, setRecent] = useState<string[]>(() => stored('recent', []));
  const [query, setQuery] = useState('');
  const [submittedQuery, setSubmittedQuery] = useState('');
  const [searchNote, setSearchNote] = useState('');
  const [editingAddress, setEditingAddress] = useState(false);
  const [address, setAddress] = useState('');
  const [refresh, setRefresh] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [operation, setOperation] = useState('');
  const operationLock = useRef(false);
  const [toast, setToast] = useState('');
  const [clipboard, setClipboard] = useState<ClipboardInfo>({ paths: [], cut: false });
  const [undoLabel, setUndoLabel] = useState<string | null>(null);
  const [popup, setPopup] = useState<Popup | null>(null);
  const [modal, setModal] = useState<Modal | null>(null);
  const [modalValue, setModalValue] = useState('');
  const [modalError, setModalError] = useState('');
  const [editingName, setEditingName] = useState<{ path: string; name: string } | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [dragOver, setDragOver] = useState<string | null>(null);
  const addressRef = useRef<HTMLInputElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const generation = useRef(0);
  const loadedLocation = useRef('');
  const [openPaths, setOpenPaths] = useState<string[]>([]);
  const [revealedPaths, setRevealedPaths] = useState<string[]>([]);
  const pendingSelection = useRef<{ directory: string; paths: string[] } | null>(null);

  useEffect(() => {
    const receive = () => api.takeOpenPaths().then(paths => { if (paths.length) setOpenPaths(previous => [...previous, ...paths]); }).catch(e => setToast(errorMessage(e)));
    const unsubscribe = api.onOpenPaths(receive);
    void receive();
    return unsubscribe;
  }, []);
  useEffect(() => {
    if (!boot || !openPaths.length || modal || operation || editingName) return;
    let live = true;
    Promise.all(openPaths.map(p => api.info(p).catch(e => { if (live) setToast(errorMessage(e)); return null; }))).then(results => {
      if (!live) return;
      const targets = results.filter((entry): entry is FileEntry => entry !== null);
      setOpenPaths(previous => previous.slice(openPaths.length));
      if (!targets.length) return;
      const directoryFor = (entry: FileEntry) => entry.isDirectory && !entry.name.endsWith('.app') ? entry.path : parent(entry.path);
      const directory = directoryFor(targets[targets.length - 1]);
      const nextTabs = [...tabs];
      for (const entry of targets) if (!nextTabs.some(t => t.location === directoryFor(entry))) nextTabs.push(makeTab(directoryFor(entry)));
      resetNavigation();
      const paths = targets.filter(e => directoryFor(e) === directory && e.path !== directory).map(e => e.path);
      pendingSelection.current = { directory, paths };
      setRevealedPaths(paths); setTabs(nextTabs); setActiveID(nextTabs.find(t => t.location === directory)!.id);
      setRefresh(value => value + 1);
    });
    return () => { live = false; };
  }, [boot, openPaths, modal, operation, editingName, tabs]);

  useEffect(() => { api.bootstrap().then(data => {
    setBoot(data); setTheme(data.theme);
    const saved = stored<string[]>('tabs', [HOME]).filter(p => typeof p === 'string' && (isVirtual(p) || p.startsWith('/'))).slice(0, 12);
    const initial = (data.initialPath ? [data.initialPath] : saved.length ? saved : [HOME]).map(makeTab);
    setTabs(initial); setActiveID(initial[0].id);
  }).catch(e => { setError(errorMessage(e)); setLoading(false); }); }, []);
  useEffect(() => { for (const [key, value] of Object.entries({ view, iconSize, sort, ascending, hidden, extensions, details, previewPane, navigationPane, compact, checkboxes, pins, unpinnedDefaults, recent })) localStorage.setItem(key, JSON.stringify(value)); }, [view, iconSize, sort, ascending, hidden, extensions, details, previewPane, navigationPane, compact, checkboxes, pins, unpinnedDefaults, recent]);
  useEffect(() => { if (boot) localStorage.setItem('tabs', JSON.stringify(tabs.map(t => t.location))); }, [tabs, boot]);
  useEffect(() => { if (!toast) return; const timer = setTimeout(() => setToast(''), 4500); return () => clearTimeout(timer); }, [toast]);
  useEffect(() => {
    if (!boot) return;
    const version = ++generation.current;
    setLoading(loadedLocation.current !== location || !!submittedQuery); setError(''); setSearchNote('');
    const load = async () => {
      if (submittedQuery) {
        const result = await api.search(isVirtual(location) ? boot.home : location, submittedQuery, hidden);
        if (version === generation.current) setSearchNote([result.truncated ? '已达到搜索上限，请缩小范围（最多 1,000 个结果 / 30,000 个项目）' : '', result.skipped ? `${result.skipped} 个位置无法访问` : ''].filter(Boolean).join(' · '));
        return result.entries;
      }
      if (location === PC) return [];
      if (location === HOME) return (await Promise.all(recent.slice(0, 16).map(p => api.info(p).catch(() => null)))).filter((e): e is FileEntry => e !== null);
      return (await api.list(location)).entries;
    };
    load().then(items => {
      if (version !== generation.current) return;
      loadedLocation.current = location; setEntries(items);
      const reveal = pendingSelection.current?.directory === location ? pendingSelection.current : null;
      if (reveal) pendingSelection.current = null;
      setSelected(previous => new Set((reveal ? reveal.paths : [...previous]).filter(p => items.some(e => e.path === p))));
    }).catch(e => { if (version === generation.current) { setEntries([]); setError(errorMessage(e)); } }).finally(() => { if (version === generation.current) setLoading(false); });
    return () => { generation.current++; api.cancelSearch().catch(() => {}); };
  }, [boot, location, refresh, submittedQuery, hidden, recent]);
  useEffect(() => {
    if (!boot) return;
    api.watch(isVirtual(location) || submittedQuery ? null : location).catch(() => {});
    return api.onDirectoryChange(() => setRefresh(v => v + 1));
  }, [boot, location, submittedQuery]);
  useEffect(() => {
    const update = () => api.clipboardGet().then(setClipboard).catch(() => {});
    update(); window.addEventListener('focus', update);
    return () => window.removeEventListener('focus', update);
  }, []);

  const places = useMemo<Place[]>(() => [...(boot?.places || []).filter(place => !unpinnedDefaults.includes(place.path)), ...pins.filter(p => !boot?.places.some(place => place.path === p)).map(p => ({ path: p, name: base(p), icon: 'folder' }))], [boot, pins, unpinnedDefaults]);
  const label = useCallback((value: string) => value === HOME ? '主页' : value === PC ? '此电脑' : value === boot?.home ? '个人文件夹' : boot?.places.find(p => p.path === value)?.name || places.find(p => p.path === value)?.name || base(value), [boot, places]);
  const displayName = (entry: FileEntry) => extensions || entry.isDirectory || !entry.extension ? entry.name : entry.name.slice(0, -(entry.extension.length + 1));
  const visible = useMemo(() => {
    const items = entries.filter(e => hidden || !e.hidden || revealedPaths.includes(e.path));
    if (location === HOME && !submittedQuery) return items;
    return items.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
      const comparison = sort === 'name' ? a.name.localeCompare(b.name, 'zh-CN', { numeric: true, sensitivity: 'base' }) : sort === 'modified' ? a.modified - b.modified : sort === 'size' ? a.size - b.size : type(a).localeCompare(type(b), 'zh-CN');
      return (ascending ? 1 : -1) * (comparison || a.name.localeCompare(b.name));
    });
  }, [entries, hidden, revealedPaths, location, submittedQuery, sort, ascending]);
  useEffect(() => {
    if (!loading && revealedPaths.length) contentRef.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' });
  }, [loading, entries, revealedPaths]);
  const chosen = visible.filter(e => selected.has(e.path));
  const single = chosen.length === 1 ? chosen[0] : null;
  const writable = !isVirtual(location) && !submittedQuery;
  useEffect(() => {
    let live = true; setPreview(null);
    if ((details || previewPane) && single) api.preview(single.path).then(value => { if (live) setPreview(value); }).catch(() => { if (live) setPreview({ kind: 'none', content: '' }); });
    return () => { live = false; };
  }, [details, previewPane, single?.path, single?.modified]);

  function toggleDetails(value = !details) { setDetails(value); if (value) setPreviewPane(false); }
  function togglePreview() { setPreviewPane(!previewPane); if (!previewPane) setDetails(false); }
  function resetNavigation() { pendingSelection.current = null; setRevealedPaths([]); setSelected(new Set()); selectionAnchor.current = null; setQuery(''); setSubmittedQuery(''); setEditingAddress(false); setEditingName(null); setPopup(null); }
  function navigate(destination: string) {
    resetNavigation();
    setTabs(previous => previous.map(t => t.id === tab.id ? { ...t, location: destination, history: [...t.history.slice(0, t.index + 1), destination], index: t.index + 1 } : t));
  }
  function historyGo(offset: number) {
    const index = tab.index + offset;
    if (index < 0 || index >= tab.history.length) return;
    resetNavigation(); setTabs(previous => previous.map(t => t.id === tab.id ? { ...t, index, location: t.history[index] } : t));
  }
  function newTab(destination = HOME) { const next = makeTab(destination); setTabs(previous => [...previous, next]); setActiveID(next.id); resetNavigation(); }
  function closeTab(id: string) {
    if (tabs.length === 1) { navigate(HOME); return; }
    const index = tabs.findIndex(t => t.id === id);
    if (id === tab.id) { setActiveID(tabs[index === 0 ? 1 : index - 1].id); resetNavigation(); }
    setTabs(previous => previous.filter(t => t.id !== id));
  }
  async function run(title: string, action: () => Promise<unknown>, success?: string): Promise<boolean> {
    if (operationLock.current) return false;
    operationLock.current = true; setOperation(title); setError('');
    try { await action(); if (success) setToast(success); return true; }
    catch (e) { setError(errorMessage(e)); return false; }
    finally { operationLock.current = false; setOperation(''); api.history().then(setUndoLabel).catch(() => {}); }
  }
  function report(result: OperationResult, verb: string) {
    if (result.succeeded.length) setToast(`${verb} ${result.succeeded.length} 个项目`);
    if (result.errors.length) setError(result.errors.slice(0, 3).map(e => `${base(e.path)}：${e.message}`).join('\n') + (result.errors.length > 3 ? `\n另有 ${result.errors.length - 3} 项未完成。` : ''));
    setRefresh(v => v + 1);
  }
  function openEntry(entry: FileEntry) {
    if (entry.isDirectory && !entry.name.endsWith('.app')) navigate(entry.path);
    else run('正在打开…', () => openFile(entry));
  }
  async function openFile(entry: FileEntry) {
    const archive = await api.open(entry.path);
    if (archive) showModal({ kind: 'archive', archive });
    setRecent(previous => [entry.path, ...previous.filter(p => p !== entry.path)].slice(0, 30));
  }
  function copy(cut: boolean, paths = [...selected]) {
    if (!paths.length) return;
    run(cut ? '正在剪切…' : '正在复制…', async () => { setClipboard(await api.clipboardSet(paths, cut)); }, `已${cut ? '剪切' : '复制'} ${paths.length} 个项目，请到目标文件夹粘贴`);
  }
  function paste() { if (writable) run('正在粘贴…', async () => { report(await api.paste(location), '已粘贴'); setClipboard(await api.clipboardGet()); }); }
  function undo() { if (undoLabel) run('正在撤销…', async () => report(await api.undo(), '已撤销')); }
  function showModal(next: Modal) { setPopup(null); setModalError(''); setModal(next); setModalValue('name' in next ? next.name : ''); }
  function create(directory: boolean) {
    if (!writable) return;
    run('正在新建…', async () => {
      const stem = directory ? '新建文件夹' : '新建文本文档'; const ext = directory ? '' : '.txt';
      let name = stem + ext; let index = 2;
      while (entries.some(e => e.name === name)) name = `${stem} (${index++})${ext}`;
      const path = await api.create(location, name, directory);
      const entry = await api.info(path);
      setEntries(previous => [...previous.filter(e => e.path !== path), entry]);
      setSelected(new Set([path])); setEditingName({ path, name });
    });
  }
  function rename(entry = single) { if (entry) { setPopup(null); setEditingName({ path: entry.path, name: entry.name }); } }
  async function finishRename(name: string) {
    if (!editingName || operationLock.current) return;
    const editing = editingName;
    if (name === editing.name) { setEditingName(null); contentRef.current?.focus(); return; }
    const success = await run('正在重命名…', async () => {
      const destination = await api.rename(editing.path, name);
      const entry = await api.info(destination);
      setEntries(previous => previous.map(e => e.path === editing.path ? entry : e));
      setSelected(new Set([destination]));
      setRecent(previous => previous.map(p => p === editing.path ? destination : p));
      setPins(previous => previous.map(p => p === editing.path ? destination : p));
    }, '已重命名');
    if (success) { setEditingName(null); contentRef.current?.focus(); }
  }
  function trash(paths = [...selected]) { if (paths.length) showModal({ kind: 'trash', paths }); }
  async function submitModal() {
    if (!modal || (modal.kind === 'shortcuts' || modal.kind === 'archive') || operationLock.current) return;
    operationLock.current = true; setOperation('正在处理…'); setModalError('');
    try {
      if (modal.kind === 'trash') { report(await api.trash(modal.paths), '已移到废纸篓'); setSelected(new Set()); }
      else {
        const result = modal.kind === 'rename' ? await api.rename(modal.path, modalValue) : await api.create(modal.path, modalValue, modal.kind === 'folder');
        setSelected(new Set([result])); setRefresh(v => v + 1);
        setToast(modal.kind === 'rename' ? '已重命名' : '已新建');
      }
      setModal(null); contentRef.current?.focus();
    } catch (e) { setModalError(errorMessage(e)); }
    finally { operationLock.current = false; setOperation(''); api.history().then(setUndoLabel).catch(() => {}); }
  }
  function togglePin(path: string) {
    const pinned = places.some(place => place.path === path);
    if (boot?.places.some(place => place.path === path)) {
      setUnpinnedDefaults(previous => pinned ? [...new Set([...previous, path])] : previous.filter(p => p !== path));
      setPins(previous => previous.filter(p => p !== path));
    } else setPins(previous => pinned ? previous.filter(p => p !== path) : [...new Set([...previous, path])]);
  }
  function chooseFolder() { run('选择文件夹…', async () => { const path = await api.chooseFolder(); if (path) navigate(path); }); }
  function terminalItem(directory: string): MenuItem {
    return { label: '在此处打开终端', icon: <Terminal/>, disabled: isVirtual(directory), action: () => run('正在打开终端…', () => api.openTerminal(directory)) };
  }
  function select(entry: FileEntry, event: MouseEvent) {
    setPopup(null); contentRef.current?.focus();
    if (event.shiftKey && selectionAnchor.current) {
      const start = visible.findIndex(e => e.path === selectionAnchor.current); const end = visible.indexOf(entry);
      if (start >= 0) { const range = visible.slice(Math.min(start, end), Math.max(start, end) + 1).map(e => e.path); setSelected(new Set(event.metaKey || event.ctrlKey ? [...selected, ...range] : range)); return; }
    }
    if (event.metaKey || event.ctrlKey) setSelected(previous => { const next = new Set(previous); if (next.has(entry.path)) next.delete(entry.path); else next.add(entry.path); return next; });
    else setSelected(new Set([entry.path]));
    selectionAnchor.current = entry.path;
  }
  function menuAt(event: MouseEvent, items: MenuItem[], quickActions?: MenuItem[]) { event.preventDefault(); event.stopPropagation(); setPopup({ x: event.clientX, y: event.clientY, items, quickActions }); }
  function buttonMenu(event: MouseEvent<HTMLButtonElement>, items: MenuItem[]) { const rect = event.currentTarget.getBoundingClientRect(); setPopup(popup ? null : { x: rect.left, y: rect.bottom + 5, items }); }
  function contextMenu(event: MouseEvent, entry?: FileEntry) {
    event.stopPropagation();
    const paths = entry && !selected.has(entry.path) ? [entry.path] : [...selected];
    if (entry && !selected.has(entry.path)) setSelected(new Set([entry.path]));
    const target = paths.length === 1 ? entry || single : null;
    const items: MenuItem[] = entry ? [
      { label: '打开', icon: <FolderOpen/>, action: () => openEntry(entry) },
      ...(!entry.isDirectory ? [{ label: '打开方式…', icon: <ExternalLink/>, disabled: paths.some(p => visible.find(item => item.path === p)?.isDirectory), action: () => run('选择打开方式…', async () => {
        if (await api.openWith(paths)) setRecent(previous => [...paths, ...previous.filter(p => !paths.includes(p))].slice(0, 30));
      }) }] : []),
      ...(!entry.isDirectory && isArchive(entry.path) ? ([['choose', '解压到…'], ['here', '解压到当前目录'], ['folder', `解压到“${archiveFolderName(entry.name)}/”`]] as const).map(([mode, label]) => ({ label, icon: <Download/>, disabled: paths.length !== 1, action: () => run('正在解压…', async () => {
        const result = await api.extractArchive(entry.path, null, mode); if (result) report(result, '已解压');
      }) })) : []),
      ...(entry.isDirectory ? [{ label: '在新标签页中打开', icon: <Plus/>, action: () => newTab(entry.path) }] : [{ label: '快速查看', icon: <Search/>, shortcut: 'Space', action: () => run('正在预览…', () => api.quickLook(entry.path)) }]),
      ...(entry.isDirectory ? [terminalItem(entry.path)] : []),
      { label: '压缩为 ZIP', icon: <Archive/>, action: () => run('正在压缩…', async () => {
        const output = await api.compressArchive(paths);
        report({ succeeded: [output], errors: [] }, '已压缩');
        setSelected(new Set([output])); setToast(`已创建 ${base(output)}`);
      }) },
      { label: '剪切', icon: <Scissors/>, shortcut: 'Ctrl+X', divider: true, action: () => copy(true, paths) },
      { label: '复制', icon: <Copy/>, shortcut: 'Ctrl+C', action: () => copy(false, paths) },
      { label: '复制文件地址', icon: <Copy/>, action: () => run('复制地址…', () => api.copyText(paths.join('\n')), '已复制文件地址') },
      { label: '重命名', icon: <TextCursorInput/>, shortcut: 'F2', disabled: paths.length !== 1, action: () => rename(target) },
      { label: '移到废纸篓', icon: <Trash2/>, shortcut: 'Delete', danger: true, action: () => trash(paths) },
      ...(entry.isDirectory ? [{ label: places.some(place => place.path === entry.path) ? '从快速访问取消固定' : '固定到快速访问', icon: <Pin/>, divider: true, action: () => togglePin(entry.path) }] : []),
      { label: '在访达中显示', icon: <ExternalLink/>, divider: true, action: () => run('正在显示…', () => api.reveal(entry.path)) },
      { label: '属性', icon: <Info/>, shortcut: 'Alt+Enter', action: () => toggleDetails(true) },
    ] : [
      { label: '新建文件夹', icon: <FolderPlus/>, disabled: !writable, action: () => create(true) },
      { label: '新建文本文档', icon: <FilePlus2/>, disabled: !writable, action: () => create(false) },
      { label: '粘贴', icon: <ClipboardPaste/>, shortcut: 'Ctrl+V', divider: true, disabled: !writable || !clipboard.paths.length, action: paste },
      { label: undoLabel ? `撤销${undoLabel}` : '撤销', icon: <Undo2/>, shortcut: 'Ctrl+Z', disabled: !undoLabel, action: undo },
      { label: '刷新', icon: <RotateCw/>, shortcut: 'F5', action: () => setRefresh(v => v + 1) },
      { label: '显示隐藏的项目', checked: hidden, divider: true, action: () => setHidden(v => !v) },
      { label: '打开文件夹…', icon: <FolderOpen/>, action: chooseFolder },
      ...(!isVirtual(location) ? [terminalItem(location)] : []),
    ];
    const quickActions: MenuItem[] | undefined = entry ? [
      { label: '剪切', icon: <Scissors/>, action: () => copy(true, paths) },
      { label: '复制', icon: <Copy/>, action: () => copy(false, paths) },
      { label: '重命名', icon: <TextCursorInput/>, disabled: paths.length !== 1, action: () => rename(target) },
      { label: '共享', icon: <Share2/>, action: () => run('共享文件…', () => api.share(paths)) },
      { label: '删除', icon: <Trash2/>, action: () => trash(paths) },
    ] : undefined;
    menuAt(event, entry ? items.filter(item => !['剪切', '复制', '重命名', '移到废纸篓'].includes(item.label)) : items, quickActions);
  }
  const sortMenu: MenuItem[] = [
    ...(['name', 'modified', 'type', 'size'] as SortKey[]).map(key => ({ label: ({ name: '名称', modified: '修改日期', type: '类型', size: '大小' })[key], checked: sort === key, action: () => setSort(key) })),
    { label: '递增', checked: ascending, divider: true, action: () => setAscending(true) },
    { label: '递减', checked: !ascending, action: () => setAscending(false) },
  ];
  const viewMenu: MenuItem[] = [
    ...[{ name: '超大图标', size: 128, icon: <ViewGlyph mode="extra"/> }, { name: '大图标', size: 64, icon: <ViewGlyph mode="large"/> }, { name: '中图标', size: 48, icon: <ViewGlyph mode="medium"/> }, { name: '小图标', size: 32, icon: <ViewGlyph mode="small"/> }].map(option => ({ label: option.name, icon: option.icon, radio: true, checked: view === 'icons' && iconSize === option.size, action: () => { setIconSize(option.size); setView('icons'); } })),
    { label: '列表', icon: <ViewGlyph mode="list"/>, radio: true, checked: view === 'list', action: () => setView('list') },
    { label: '详细信息', icon: <ViewGlyph mode="details"/>, radio: true, checked: view === 'details', action: () => setView('details') },
    { label: '平铺', icon: <ViewGlyph mode="tiles"/>, radio: true, checked: view === 'tiles', action: () => setView('tiles') },
    { label: '内容', icon: <ViewGlyph mode="content"/>, radio: true, checked: view === 'content', action: () => setView('content') },
    { label: '详细信息窗格', icon: <PanelRight/>, checked: details, divider: true, action: () => toggleDetails() },
    { label: '预览窗格', icon: <PanelRight/>, checked: previewPane, action: togglePreview },
    { label: '显示', divider: true, children: [
      { label: '导航窗格', icon: <PanelLeft/>, checked: navigationPane, action: () => setNavigationPane(v => !v) },
      { label: '紧凑视图', icon: <ChevronsDownUp/>, checked: compact, divider: true, action: () => setCompact(v => !v) },
      { label: '项目复选框', icon: <SquareCheck/>, checked: checkboxes, divider: true, action: () => setCheckboxes(v => !v) },
      { label: '文件扩展名', icon: <FileType/>, checked: extensions, action: () => setExtensions(v => !v) },
      { label: '隐藏的项目', icon: <Eye/>, checked: hidden, action: () => setHidden(v => !v) },
    ] },
  ];
  async function goAddress() {
    let path = address.trim();
    if (path === '~' || path.startsWith('~/')) path = boot!.home + path.slice(1);
    if (path.startsWith('file://')) { try { path = decodeURIComponent(new URL(path).pathname); } catch { setError('文件地址格式不正确。'); return; } }
    if (!path.startsWith('/')) path = join(isVirtual(location) ? boot!.home : location, path);
    await run('正在打开位置…', async () => {
      const entry = await api.info(path);
      if (entry.isDirectory && !entry.name.endsWith('.app')) navigate(entry.path);
      else { await openFile(entry); setEditingAddress(false); }
    });
  }
  function drop(event: React.DragEvent, destination: string) {
    event.preventDefault(); event.stopPropagation(); setDragOver(null);
    if (isVirtual(destination)) return;
    let paths: string[] = [];
    try { paths = JSON.parse(event.dataTransfer.getData('application/x-explorer-paths') || '[]'); } catch { /* External drop. */ }
    if (!paths.length) paths = Array.from(event.dataTransfer.files).map(file => api.filePath(file)).filter(Boolean);
    if (paths.length) run('正在复制拖入的文件…', async () => report(await api.copyTo(paths, destination), '已复制'));
  }

  const actions = useRef<(action: string) => void>(() => {});
  actions.current = action => {
    if (modal) return;
    if (document.activeElement instanceof HTMLInputElement) {
      const command = ({ copy: 'copy', cut: 'cut', paste: 'paste', 'select-all': 'selectAll', undo: 'undo' } as Record<string, string>)[action];
      if (command) { document.execCommand(command); return; }
    }
    if (action === 'new-tab') newTab(); if (action === 'choose-folder') chooseFolder();
    if (action === 'new-folder') create(true); if (action === 'refresh') setRefresh(v => v + 1);
    if (action === 'hidden') setHidden(v => !v);
    if (action === 'close-tab') closeTab(tab.id); if (action === 'copy') copy(false); if (action === 'cut') copy(true);
    if (action === 'paste') paste(); if (action === 'undo') undo(); if (action === 'select-all') setSelected(new Set(visible.map(e => e.path)));
  };
  useEffect(() => api.onAction(action => actions.current(action)), []);
  useEffect(() => {
    const keydown = (event: globalThis.KeyboardEvent) => {
      const input = event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement;
      const ctrl = event.ctrlKey || event.metaKey; const key = event.key.toLowerCase();
      if (modal || popup) return;
      if (ctrl && key === 'l' || event.altKey && key === 'd') { event.preventDefault(); setAddress(isVirtual(location) ? boot?.home || '/' : location); setEditingAddress(true); return; }
      if (ctrl && (key === 'f' || key === 'e')) { event.preventDefault(); searchRef.current?.focus(); searchRef.current?.select(); return; }
      if (input) return;
      if (ctrl && key === 'c') { event.preventDefault(); copy(false); }
      else if (ctrl && key === 'x') { event.preventDefault(); copy(true); }
      else if (ctrl && key === 'v') { event.preventDefault(); paste(); }
      else if (ctrl && key === 'z') { event.preventDefault(); undo(); }
      else if (ctrl && key === 'a') { event.preventDefault(); setSelected(new Set(visible.map(e => e.path))); }
      else if (ctrl && key === 't') { event.preventDefault(); newTab(); }
      else if (ctrl && key === 'w') { event.preventDefault(); closeTab(tab.id); }
      else if (ctrl && event.shiftKey && key === 'n') { event.preventDefault(); create(true); }
      else if (ctrl && key === 'i' || event.altKey && key === 'enter') { event.preventDefault(); toggleDetails(); }
      else if (ctrl && key === 'tab') { event.preventDefault(); const index = tabs.findIndex(t => t.id === tab.id); setActiveID(tabs[(index + (event.shiftKey ? tabs.length - 1 : 1)) % tabs.length].id); resetNavigation(); }
      else if (key === 'f2') { event.preventDefault(); rename(); }
      else if (key === 'f5' || ctrl && key === 'r') { event.preventDefault(); setRefresh(v => v + 1); }
      else if (key === 'delete' || event.metaKey && key === 'backspace') { event.preventDefault(); trash(); }
      else if (event.altKey && key === 'arrowleft') { event.preventDefault(); historyGo(-1); }
      else if (event.altKey && key === 'arrowright') { event.preventDefault(); historyGo(1); }
      else if (key === 'backspace' || event.altKey && key === 'arrowup') { event.preventDefault(); if (!isVirtual(location) && location !== '/') navigate(parent(location)); }
      else if (key === 'enter' && single) { event.preventDefault(); openEntry(single); }
      else if (key === ' ' && single) { event.preventDefault(); run('正在预览…', () => api.quickLook(single.path)); }
      else if (key === 'escape') { setSelected(new Set()); setSubmittedQuery(''); setQuery(''); }
      else if (['arrowdown', 'arrowup', 'home', 'end'].includes(key) && visible.length) {
        event.preventDefault();
        const index = visible.findIndex(e => e.path === [...selected].at(-1));
        const next = key === 'home' ? 0 : key === 'end' ? visible.length - 1 : Math.max(0, Math.min(visible.length - 1, index + (key === 'arrowdown' ? 1 : -1)));
        if (event.shiftKey) setSelected(previous => new Set([...previous, visible[next].path]));
        else setSelected(new Set([visible[next].path]));
        selectionAnchor.current = visible[next].path;
        document.querySelector(`[data-index="${next}"]`)?.scrollIntoView({ block: 'nearest' });
      }
    };
    window.addEventListener('keydown', keydown); return () => window.removeEventListener('keydown', keydown);
  });
  useEffect(() => { if (editingAddress) { addressRef.current?.focus(); addressRef.current?.select(); } }, [editingAddress]);
  useEffect(() => {
    const element = contentRef.current;
    const zoomIcons = (event: WheelEvent) => {
      if (!event.ctrlKey || !event.deltaY) return;
      event.preventDefault();
      setView('icons'); setIconSize(previous => Math.min(128, Math.max(32, previous + (event.deltaY < 0 ? 8 : -8))));
    };
    element?.addEventListener('wheel', zoomIcons, { passive: false });
    return () => element?.removeEventListener('wheel', zoomIcons);
  }, []);

  function editAddress() {
    if (editingAddress) return;
    setAddress(isVirtual(location) ? boot?.home || '/' : location); setEditingAddress(true);
  }

  const breadcrumbs = !isVirtual(location) ? [{ path: '/', name: 'Macintosh HD' }, ...location.split('/').filter(Boolean).map((part, index, parts) => ({ path: '/' + parts.slice(0, index + 1).join('/'), name: label('/' + parts.slice(0, index + 1).join('/')) }))] : [];
  const totalSelected = chosen.reduce((sum, e) => sum + (e.isDirectory ? 0 : e.size), 0);

  function fileRows() {
    return <div className={`file-items ${view === 'icons' ? `icon-grid ${iconSize === 32 ? 'small-icons' : ''}` : view === 'details' ? 'file-table' : view === 'content' ? 'file-content-view' : `file-${view}`} ${checkboxes ? 'with-checkboxes' : ''}`} style={view === 'icons' ? { '--file-icon-size': `${iconSize}px` } as CSSProperties : undefined} role="listbox" aria-label="文件列表" aria-multiselectable="true">
      {view === 'details' && <div className="table-heading" role="presentation">
        {checkboxes && <input className="select-all-checkbox" type="checkbox" aria-label="全选文件" checked={visible.length > 0 && chosen.length === visible.length} ref={element => { if (element) element.indeterminate = chosen.length > 0 && chosen.length < visible.length; }} onChange={event => setSelected(new Set(event.target.checked ? visible.map(entry => entry.path) : []))}/>}
        {(['name', 'modified', 'type', 'size'] as SortKey[]).map(key => <button key={key} className={`col-${key}`} onClick={() => { if (sort === key) setAscending(v => !v); else { setSort(key); setAscending(true); } }}>{({ name: '名称', modified: '修改日期', type: '类型', size: '大小' })[key]}{sort === key && <ChevronDown size={12} className={ascending ? 'rotated' : ''}/>}</button>)}
      </div>}
      {visible.map((entry, index) => <div key={entry.path} data-path={entry.path} data-index={index} role="option" aria-selected={selected.has(entry.path)} aria-label={entry.name}
        className={`file-row ${selected.has(entry.path) ? 'selected' : ''} ${clipboard.cut && clipboard.paths.includes(entry.path) ? 'cut' : ''} ${dragOver === entry.path ? 'drop-target' : ''} ${entry.hidden ? 'hidden-file' : ''}`}
        onClick={event => select(entry, event)} onDoubleClick={() => openEntry(entry)} onContextMenu={event => contextMenu(event, entry)} draggable
        onDragStart={event => { const paths = selected.has(entry.path) ? [...selected] : [entry.path]; event.dataTransfer.setData('application/x-explorer-paths', JSON.stringify(paths)); event.dataTransfer.effectAllowed = 'copy'; setPopup(null); }}
        onDragOver={event => { if (entry.isDirectory) { event.preventDefault(); event.stopPropagation(); event.dataTransfer.dropEffect = 'copy'; setDragOver(entry.path); } }}
        onDragLeave={() => setDragOver(null)} onDrop={event => { if (entry.isDirectory) drop(event, entry.path); }}>
        {checkboxes && <input className="item-checkbox" type="checkbox" aria-label={`选择 ${entry.name}`} checked={selected.has(entry.path)} onClick={event => event.stopPropagation()} onDoubleClick={event => event.stopPropagation()} onChange={event => { const checked = event.target.checked; setSelected(previous => { const next = new Set(previous); if (checked) next.add(entry.path); else next.delete(entry.path); return next; }); selectionAnchor.current = entry.path; }}/>}
        <div className="col-name"><FileGlyph entry={entry} dimension={view === 'icons' ? iconSize : view === 'tiles' ? 48 : view === 'content' ? 56 : 22}/>{editingName?.path === entry.path ? <InlineName key={editingName.path} name={editingName.name} directory={entry.isDirectory} onSave={finishRename} onCancel={() => { setEditingName(null); contentRef.current?.focus(); }}/> : <span className="entry-name" title={entry.name}>{displayName(entry)}{(view === 'tiles' || view === 'content') && <small>{type(entry)}{!entry.isDirectory && ` · ${size(entry.size)}`}</small>}{submittedQuery && <small>{parent(entry.path)}</small>}</span>}</div>
        {view === 'content' && <div className="content-metadata"><span>修改日期：{date(entry.modified)}</span><span title={entry.path}>位置：{parent(entry.path)}</span></div>}
        {view === 'details' && <><span className="col-modified">{date(entry.modified)}</span><span className="col-type">{type(entry)}</span><span className="col-size">{entry.isDirectory ? '' : size(entry.size)}</span></>}
      </div>)}
    </div>;
  }

  return <div className={`explorer-shell ${compact ? 'compact-view' : ''}`} onPointerDown={() => { if (popup) setPopup(null); }}>
    <header className="tab-strip">
      <div className="traffic-light-space"/>
      <div className="tabs" role="tablist" aria-label="文件夹标签页">
        {tabs.map(t => <div key={t.id} className={`tab ${t.id === tab.id ? 'current' : ''}`}>
          <button role="tab" aria-selected={t.id === tab.id} className="tab-label" onClick={() => { setActiveID(t.id); resetNavigation(); }} onAuxClick={event => { if (event.button === 1) closeTab(t.id); }}>
            {isVirtual(t.location) ? <PlaceIcon icon={t.location} size={16}/> : <FolderGlyph dimension={21}/>}<span>{label(t.location)}</span>
          </button>
          <button className="tab-close" aria-label={`关闭 ${label(t.location)} 标签页`} onClick={() => closeTab(t.id)}><X size={13}/></button>
        </div>)}
      </div>
      <ToolButton label="新建标签页 (Ctrl+T)" className="new-tab" onClick={() => newTab()}><Plus size={17}/></ToolButton>
    </header>

    <div className="navigation-bar">
      <div className="history-controls">
        <ToolButton label="后退 (Alt+←)" disabled={tab.index === 0} onClick={() => historyGo(-1)}><ArrowLeft/></ToolButton>
        <ToolButton label="前进 (Alt+→)" disabled={tab.index >= tab.history.length - 1} onClick={() => historyGo(1)}><ArrowRight/></ToolButton>
        <ToolButton label="向上一级 (Alt+↑)" disabled={isVirtual(location) || location === '/'} onClick={() => navigate(parent(location))}><ArrowUp/></ToolButton>
        <ToolButton label="刷新 (F5)" onClick={() => setRefresh(v => v + 1)}><RotateCw className={loading ? 'spinning' : ''}/></ToolButton>
      </div>
      <div className={`address-bar ${editingAddress ? 'editing' : ''}`} onClick={editAddress}>
        <span className="address-icon"><PlaceIcon icon={isVirtual(location) ? location : 'folder'} size={17}/></span>
        {editingAddress ? <form onSubmit={event => { event.preventDefault(); goAddress(); }}><input ref={addressRef} aria-label="文件夹地址" value={address} onChange={event => setAddress(event.target.value)} onBlur={() => setEditingAddress(false)} onKeyDown={event => { if (event.key === 'Escape') setEditingAddress(false); }}/></form> : <div className="breadcrumbs">
          {isVirtual(location) ? <button onClick={editAddress}>{label(location)}</button> : breadcrumbs.map(crumb => <span key={crumb.path}><ChevronRight size={13}/><button title={crumb.path === location ? '单击编辑路径' : crumb.path} onClick={event => { if (crumb.path !== location) { event.stopPropagation(); navigate(crumb.path); } }}>{crumb.name}</button></span>)}
        </div>}
        <ToolButton label="编辑地址 (Ctrl+L)" onClick={() => { setAddress(isVirtual(location) ? boot?.home || '/' : location); setEditingAddress(true); }}><ChevronDown size={14}/></ToolButton>
      </div>
      <form className="search-box" onSubmit={event => { event.preventDefault(); setSubmittedQuery(query.trim()); setSelected(new Set()); }}>
        <input ref={searchRef} aria-label="搜索文件" placeholder={`在${label(location)}中搜索`} value={query} onChange={event => { setQuery(event.target.value); if (!event.target.value) setSubmittedQuery(''); }}/>
        {query ? <button type="button" title="清除搜索" aria-label="清除搜索" onClick={() => { setQuery(''); setSubmittedQuery(''); }}><X size={15}/></button> : <Search size={17}/>}<button className="sr-only" type="submit">搜索</button>
      </form>
    </div>

    <div className="command-bar">
      <ToolButton label="新建" disabled={!writable || !!operation} className="text-tool" onClick={event => buttonMenu(event, [{ label: '文件夹', icon: <FolderPlus/>, shortcut: 'Ctrl+Shift+N', action: () => create(true) }, { label: '文本文档', icon: <FilePlus2/>, action: () => create(false) }])}><Plus className="new-icon"/><span>新建</span><ChevronDown size={12}/></ToolButton>
      <span className="toolbar-separator"/>
      <ToolButton label="剪切 (Ctrl+X)" disabled={!selected.size || !!operation} onClick={() => copy(true)}><Scissors className="scissors-icon"/></ToolButton>
      <ToolButton label="复制 (Ctrl+C)" disabled={!selected.size || !!operation} onClick={() => copy(false)}><Copy className="copy-icon"/></ToolButton>
      <ToolButton label="粘贴 (Ctrl+V)" disabled={!writable || !clipboard.paths.length || !!operation} onClick={paste}><ClipboardPaste/></ToolButton>
      <ToolButton label="重命名 (F2)" disabled={!single || !!operation} onClick={() => rename()}><TextCursorInput className="rename-icon"/></ToolButton>
      <ToolButton label="共享" disabled={!selected.size} onClick={() => run('共享文件…', () => api.share([...selected]))}><Share2/></ToolButton>
      <ToolButton label="移到废纸篓 (Delete)" disabled={!selected.size || !!operation} onClick={() => trash()}><Trash2/></ToolButton>
      <span className="toolbar-separator"/>
      <ToolButton label="排序" className="text-tool" onClick={event => buttonMenu(event, sortMenu)}><ArrowDownWideNarrow/><span>排序</span><ChevronDown size={12}/></ToolButton>
      <ToolButton label="查看" className="text-tool" onClick={event => buttonMenu(event, viewMenu)}><List/><span>查看</span><ChevronDown size={12}/></ToolButton>
      <ToolButton label="更多" onClick={event => buttonMenu(event, [
        { label: '打开文件夹…', icon: <FolderOpen/>, action: chooseFolder },
        { label: '全选', shortcut: 'Ctrl+A', action: () => setSelected(new Set(visible.map(e => e.path))) },
        { label: '取消选择', action: () => setSelected(new Set()) },
        { label: undoLabel ? `撤销${undoLabel}` : '撤销', icon: <Undo2/>, shortcut: 'Ctrl+Z', disabled: !undoLabel, divider: true, action: undo },
        { label: '清空最近使用记录', disabled: !recent.length, divider: true, action: () => setRecent([]) },
        { label: '外观', icon: <SunMoon/>, divider: true, children: [
          ...([{ mode: 'light', label: '浅色', icon: <Sun/> }, { mode: 'dark', label: '深色', icon: <Moon/> }, { mode: 'system', label: '跟随系统', icon: <Monitor/> }] as const).map(option => ({ label: option.label, icon: option.icon, radio: true, checked: theme === option.mode, action: () => run('正在切换外观…', async () => setTheme(await api.setTheme(option.mode))) })),
        ] },
        { label: '键盘快捷键', icon: <Keyboard/>, divider: true, action: () => showModal({ kind: 'shortcuts' }) },
      ])}><MoreHorizontal/></ToolButton>
      <div className="command-spacer"/>
      <ToolButton label="预览窗格" className="text-tool details-toggle" active={previewPane} onClick={togglePreview}><PanelRight/><span>预览</span></ToolButton>
    </div>

    <div className="workspace">
      {navigationPane && <nav className="sidebar" aria-label="文件位置">
        <div className="sidebar-top">
          <button className={`nav-item ${location === HOME ? 'current' : ''}`} onClick={() => navigate(HOME)}><PlaceIcon icon="home"/><span>主页</span></button>
          <button className={`nav-item ${location === boot?.home ? 'current' : ''}`} onClick={() => boot && navigate(boot.home)}><PlaceIcon icon="folder"/><span>个人文件夹</span></button>
        </div>
        <div className="nav-divider"/>
        <div className="sidebar-section" aria-label="快速访问">
          {places.map(place => <NavigationTree key={place.path} place={place} location={location} hidden={hidden} pinned navigate={navigate} newTab={newTab} drop={drop}
            context={(event, target) => menuAt(event, [{ label: '在新标签页中打开', icon: <Plus/>, action: () => newTab(target.path) }, terminalItem(target.path), { label: places.some(place => place.path === target.path) ? '从快速访问取消固定' : '固定到快速访问', icon: <Pin/>, action: () => togglePin(target.path) }])}/>)}
        </div>
        <div className="nav-divider"/>
        <button className={`nav-item parent-nav ${location === PC ? 'current' : ''}`} onClick={() => navigate(PC)}><ChevronDown className="nav-chevron" size={12}/><PlaceIcon icon="computer"/><span>此电脑</span></button>
        {boot?.volumes.map(volume => <NavigationTree key={volume.path} place={volume} location={location} hidden={hidden} navigate={navigate} newTab={newTab} drop={drop} level={1} context={(event, target) => menuAt(event, [{ label: '在新标签页中打开', icon: <Plus/>, action: () => newTab(target.path) }, terminalItem(target.path)])}/>)}
        <div className="sidebar-bottom"><button className="nav-item" onClick={chooseFolder}><FolderOpen size={17}/><span>打开文件夹</span><Plus size={13}/></button></div>
      </nav>}

      <main className={`main-pane ${details || previewPane ? 'has-details' : ''}`}>
        {error && <div className="error-bar" role="alert"><Info size={17}/><span>{error}</span><button title="关闭提示" aria-label="关闭错误提示" onClick={() => setError('')}><X size={15}/></button></div>}
        {submittedQuery && <div className="search-summary"><Search size={16}/><span>“{submittedQuery}” 的搜索结果</span><small>{loading ? '正在搜索子文件夹…' : searchNote || `${visible.length} 个匹配项目`}</small><button onClick={() => { setQuery(''); setSubmittedQuery(''); }}>退出搜索</button></div>}
        <div ref={contentRef} tabIndex={0} className={`file-content view-${view} ${dragOver === location ? 'drop-target' : ''}`} aria-label={label(location)} aria-busy={loading}
          onContextMenu={event => contextMenu(event)} onClick={event => { if (event.target === event.currentTarget) { setSelected(new Set()); setPopup(null); } }}
          onDragOver={event => { if (writable) { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; setDragOver(location); } }} onDragLeave={event => { if (!event.currentTarget.contains(event.relatedTarget as Node)) setDragOver(null); }} onDrop={event => drop(event, location)}>
          {location === HOME && !submittedQuery ? <div className="home-content">
            <h1><Home size={23} strokeWidth={1.6}/>主页</h1>
            <h2><ChevronDown size={14}/>快速访问</h2>
            <div className="quick-access">{places.map(place => <button key={place.path} onDoubleClick={() => navigate(place.path)} onKeyDown={event => { if (event.key === 'Enter') navigate(place.path); }} className="quick-folder" onContextMenu={event => menuAt(event, [{ label: '在新标签页中打开', icon: <Plus/>, action: () => newTab(place.path) }, terminalItem(place.path), { label: '从快速访问取消固定', icon: <Pin/>, action: () => togglePin(place.path) }])}><FolderGlyph dimension={59} badge={place.icon}/><span><strong>{place.name}</strong><small>{pins.includes(place.path) ? '已固定的文件夹' : '本地文件夹'}</small></span><Pin size={13}/></button>)}</div>
            <h2 className="recent-heading"><ChevronDown size={14}/>最近使用{recent.length > 0 && <button onClick={() => setRecent([])}>清除记录</button>}</h2>
            {loading ? <Loading/> : visible.length ? fileRows() : <div className="recent-empty"><FileText size={29} strokeWidth={1.3}/><div>最近打开的文件会显示在这里<p>打开一个文件，即可在主页快速找到它。</p></div></div>}
          </div> : location === PC && !submittedQuery ? <div className="computer-content"><h2><ChevronDown size={14}/>设备和驱动器（{boot?.volumes.length || 0}）</h2><div className="drive-grid">{boot?.volumes.map(volume => <button className="drive-card" key={volume.path} onDoubleClick={() => navigate(volume.path)} onKeyDown={event => { if (event.key === 'Enter') navigate(volume.path); }}><HardDrive size={49} strokeWidth={1.2}/><span><strong>{volume.name}</strong><span className="storage-track"><span style={{ width: `${Math.max(0, Math.min(100, (1 - volume.free / volume.total) * 100))}%` }}/></span><small>{size(volume.free)} 可用，共 {size(volume.total)}</small></span></button>)}</div></div> : loading ? <Loading/> : visible.length ? fileRows() : <div className="empty-state">{submittedQuery ? <Search size={42} strokeWidth={1.2}/> : <FolderGlyph dimension={68}/>}<h2>{error ? '无法显示此位置' : submittedQuery ? '没有找到匹配的项目' : '此文件夹为空'}</h2><p>{error ? '检查访问权限，或返回上一个文件夹。' : submittedQuery ? '尝试其他名称，或到上一级文件夹中搜索。' : '将文件拖到这里，或使用“新建”创建文件夹。'}</p>{error && <button className="secondary-button" onClick={() => setRefresh(v => v + 1)}>重试</button>}</div>}
        </div>
      </main>
      {details && <aside className="details-pane" aria-label="详细信息"><div className="details-header"><h2>详细信息</h2><button aria-label="关闭详细信息" onClick={() => setDetails(false)}><X size={17}/></button></div>
        {single ? <><div className="preview-hero">{preview?.kind === 'image' ? <img src={preview.content} alt={single.name}/> : <FileGlyph entry={single} dimension={70}/>}</div><h3>{single.name}</h3><p className="detail-kind">{type(single)}</p><dl><dt>位置</dt><dd title={parent(single.path)}>{parent(single.path)}</dd><dt>大小</dt><dd>{single.isDirectory ? '文件夹' : `${size(single.size)}（${single.size.toLocaleString()} 字节）`}</dd><dt>修改日期</dt><dd>{date(single.modified)}</dd><dt>创建日期</dt><dd>{date(single.created)}</dd>{single.isSymlink && <><dt>链接</dt><dd>符号链接</dd></>}</dl>{preview?.kind === 'text' && <div className="text-preview"><h4>内容预览</h4><pre>{preview.content}</pre>{preview.truncated && <small>仅显示前 16 KB</small>}</div>}<button className="secondary-button" onClick={() => run('正在预览…', () => api.quickLook(single.path))}>快速查看 <span>Space</span></button></> : <div className="details-empty">{chosen.length > 1 ? <Copy size={46} strokeWidth={1.1}/> : <FolderGlyph dimension={75}/>}<h3>{chosen.length > 1 ? `已选择 ${chosen.length} 个项目` : label(location)}</h3><p>{chosen.length > 1 ? `文件大小合计 ${size(totalSelected)}` : '选择一个文件，查看预览和详细信息。'}</p></div>}
      </aside>}
      {previewPane && <aside className="details-pane preview-pane" aria-label="预览窗格"><div className="details-header"><h2>预览</h2><button aria-label="关闭预览" onClick={() => setPreviewPane(false)}><X size={17}/></button></div>
        {!single ? <div className="details-empty"><PanelRight size={46} strokeWidth={1.1}/><p>{chosen.length > 1 ? '请选择一个文件进行预览。' : '选择要预览的文件。'}</p></div> : <><h3>{single.name}</h3>{preview?.kind === 'image' ? <img className="pane-image-preview" src={preview.content} alt={single.name}/> : preview?.kind === 'text' ? <div className="text-preview"><pre>{preview.content}</pre>{preview.truncated && <small>仅显示前 16 KB</small>}</div> : <div className="details-empty"><FileGlyph entry={single} dimension={70}/><p>{preview ? single.isDirectory ? '文件夹不提供内容预览。' : '此文件无法在窗格中预览。' : '正在加载预览…'}</p>{!single.isDirectory && <button className="secondary-button" onClick={() => run('正在预览…', () => api.quickLook(single.path))}>快速查看</button>}</div>}</>}
      </aside>}
    </div>

    <footer className="status-bar"><span>{loading ? '正在读取…' : location === PC && !submittedQuery ? `${boot?.volumes.length || 0} 个驱动器` : `${visible.length} 个项目`}</span>{selected.size > 0 && <><span className="status-divider"/><span>已选择 {selected.size} 个项目</span>{totalSelected > 0 && <span>{size(totalSelected)}</span>}</>}<span className="status-feedback" role="status">{operation ? <><Loader2 size={12} className="spinning"/>{operation}</> : toast ? <><Check size={13}/>{toast}</> : hidden ? '显示隐藏的项目' : ''}</span>{view === 'icons' && <label className="icon-size-control"><span>图标大小</span><input type="range" aria-label="图标大小" min={32} max={128} step={8} value={iconSize} onChange={event => setIconSize(Number(event.target.value))}/><output>{iconSize}</output></label>}<button className={view === 'details' ? 'current' : ''} title="详细信息视图" aria-label="详细信息视图" aria-pressed={view === 'details'} onClick={() => setView('details')}><List size={16}/></button><button className={view === 'icons' ? 'current' : ''} title="大图标视图" aria-label="大图标视图" aria-pressed={view === 'icons'} onClick={() => setView('icons')}><LayoutGrid size={15}/></button></footer>

    {popup && <ContextMenu popup={popup} onClose={() => setPopup(null)}/>}
    {modal?.kind === 'archive' && <ArchiveDialog archive={modal.archive} onExtracted={() => setRefresh(v => v + 1)} onClose={() => setModal(null)}/>}
    {modal && modal.kind !== 'archive' && <ModalDialog modal={modal} value={modalValue} onChange={setModalValue} error={modalError} busy={!!operation} onClose={() => { if (!operation) setModal(null); }} onSubmit={submitModal}/>}
  </div>;
}

function ArchiveDialog({ archive, onClose, onExtracted }: { archive: ArchivePreview; onClose: () => void; onExtracted: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const lock = useRef(false);
  const [folder, setFolder] = useState('');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<ExtractMode>('choose');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [failure, setFailure] = useState(false);
  const items = useMemo(() => {
    const result = new Map<string, boolean>();
    for (const entry of archive.entries) {
      if (!entry.path.startsWith(folder)) continue;
      const relative = entry.path.slice(folder.length);
      const slash = relative.indexOf('/');
      const name = slash < 0 ? relative : relative.slice(0, slash);
      if (name) result.set(name, !!result.get(name) || slash >= 0 || entry.directory);
    }
    return [...result].sort((a, b) => Number(b[1]) - Number(a[1]) || a[0].localeCompare(b[0], 'zh-CN', { numeric: true }));
  }, [archive, folder]);
  useEffect(() => { ref.current?.showModal(); }, []);
  useEffect(() => api.onAction(action => { if (action === 'select-all' && !lock.current) setSelected(new Set(items.map(([name]) => name))); }), [items]);
  function enter(destination: string) { setFolder(destination); setSelected(new Set()); }
  function toggle(name: string) { setSelected(previous => { const next = new Set(previous); if (next.has(name)) next.delete(name); else next.add(name); return next; }); }
  function close() { if (!lock.current) onClose(); }
  async function openMember(name: string, directory: boolean) {
    if (lock.current) return;
    if (directory) { enter(folder + name + '/'); return; }
    lock.current = true; setBusy(true); setMessage('正在打开文件…'); setFailure(false);
    try {
      await api.openArchiveFile(archive.path, folder + name);
      setMessage('已用默认应用打开临时副本。修改不会写回压缩包；需要保留修改请另存到指定位置。');
    } catch (e) { setFailure(true); setMessage(errorMessage(e)); }
    finally { lock.current = false; setBusy(false); }
  }
  async function extract(all: boolean) {
    if (lock.current) return;
    lock.current = true; setBusy(true); setMessage(''); setFailure(false);
    try {
      const result = await api.extractArchive(archive.path, all ? null : [...selected].map(name => folder + name), mode);
      if (result) {
        setFailure(!!result.errors.length);
        setMessage(`${result.succeeded.length ? `已解压到：${result.succeeded.slice(0, 2).join('、')}${result.succeeded.length > 2 ? ' 等位置' : ''}` : '未解压任何项目。'}${result.errors.length ? '\n' + result.errors.slice(0, 3).map(e => `${base(e.path)}：${e.message}`).join('\n') : ''}`);
        onExtracted();
      }
    } catch (e) { setFailure(true); setMessage(errorMessage(e)); }
    finally { lock.current = false; setBusy(false); }
  }
  return <dialog ref={ref} className="modal archive-dialog" aria-labelledby="archive-title" onCancel={event => { event.preventDefault(); close(); }} onClose={close} onKeyDown={event => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a') { event.preventDefault(); if (!busy) setSelected(new Set(items.map(([name]) => name))); }
  }}>
    <div className="archive-heading"><div className="modal-heading"><h2 id="archive-title">{archive.name}</h2><button disabled={busy} aria-label="关闭压缩包预览" onClick={close}><X size={18}/></button></div>
      <div className="archive-navigation"><ToolButton label="压缩包内向上一级" disabled={!folder || busy} onClick={() => enter(folder.slice(0, -1).slice(0, folder.slice(0, -1).lastIndexOf('/') + 1))}><ArrowUp/></ToolButton><span title={folder}>{folder || '压缩包根目录'}</span></div>
      <div className="archive-actions"><label>解压位置 <select aria-label="解压位置" title={mode === 'folder' ? archiveFolderName(archive.name) : undefined} disabled={busy} value={mode} onChange={event => setMode(event.target.value as ExtractMode)}><option value="choose">指定路径</option><option value="here">当前路径</option><option value="folder">{archiveFolderName(archive.name)}</option></select></label>
        <button className="secondary-button" disabled={busy || !selected.size} onClick={() => extract(false)}>解压选中项</button><button className="primary-button" disabled={busy || !archive.entries.length} onClick={() => extract(true)}>全部解压</button>
      </div>
    </div>
    <div className="archive-selection"><label><input type="checkbox" aria-label="全选当前目录" disabled={busy || !items.length} checked={!!items.length && selected.size === items.length} onChange={event => setSelected(new Set(event.target.checked ? items.map(([name]) => name) : []))}/>全选当前目录</label><span>保留包内目录结构 · 已选 {selected.size} 项</span></div>
    <div className="archive-list" role="list" aria-label="压缩包内容" aria-busy={busy}>{items.length ? items.map(([name, directory]) => <div key={name} className={`archive-entry ${selected.has(name) ? 'selected' : ''}`}>
      <input type="checkbox" aria-label={`选择 ${name}`} checked={selected.has(name)} disabled={busy} onChange={() => toggle(name)}/>
      <button disabled={busy} aria-label={`${name}${directory ? ' 文件夹' : ''}`} onClick={event => { if (event.ctrlKey || event.metaKey) toggle(name); else setSelected(new Set([name])); }} onDoubleClick={() => openMember(name, directory)} onKeyDown={event => { if (event.key === 'Enter') { event.preventDefault(); openMember(name, directory); } }}>
        {directory ? <FolderGlyph dimension={24}/> : <FileText size={22} strokeWidth={1.2}/>}<span>{name}</span><small>{directory ? '文件夹' : '文件'}</small>
      </button>
    </div>) : <p className="archive-empty">此压缩包为空</p>}</div>
    {message && <div className={`archive-result ${failure ? 'failed' : ''}`} role={failure ? 'alert' : 'status'}>{message}</div>}
    <div className="archive-footer"><span>{busy ? '正在处理压缩包，请稍候…' : `${items.length} 个项目 · 同名项目会跳过，不覆盖`}</span><button className="secondary-button" disabled={busy} onClick={close}>关闭</button></div>
  </dialog>;
}

function Loading() { return <div className="loading-state" aria-label="正在读取文件"><div/><div/><div/><div/><div/></div>; }
function ContextMenu({ popup, onClose, parentButton, label }: { popup: Popup; onClose: () => void; parentButton?: HTMLButtonElement; label?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: popup.x, top: popup.y });
  const [submenu, setSubmenu] = useState<{ item: MenuItem; button: HTMLButtonElement } | null>(null);
  useLayoutEffect(() => {
    const rect = ref.current!.getBoundingClientRect();
    const anchor = parentButton?.getBoundingClientRect();
    const x = anchor ? anchor.right + 5 + rect.width <= window.innerWidth - 8 ? anchor.right + 5 : anchor.left - rect.width - 5 : popup.x;
    setPosition({ left: Math.max(8, Math.min(x, window.innerWidth - rect.width - 8)), top: Math.max(8, Math.min(anchor?.top ?? popup.y, window.innerHeight - rect.height - 8)) });
    setSubmenu(null);
    if (!parentButton) ref.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
  }, [popup, parentButton]);
  useEffect(() => {
    const dismiss = () => onClose();
    window.addEventListener('resize', dismiss);
    return () => window.removeEventListener('resize', dismiss);
  }, [onClose]);
  const openSubmenu = (item: MenuItem, button: HTMLButtonElement, focus = false) => {
    setSubmenu({ item, button });
    if (focus) requestAnimationFrame(() => document.querySelector<HTMLButtonElement>('.context-submenu button:not(:disabled)')?.focus());
  };
  return <><div className={`context-menu ${parentButton ? 'context-submenu' : ''}`} role="menu" aria-label={label} ref={ref} style={position} onPointerDown={e => e.stopPropagation()} onScroll={() => setSubmenu(null)} onKeyDown={event => {
    event.stopPropagation();
    if (event.key === 'Escape' || event.key === 'ArrowLeft' && parentButton) { event.preventDefault(); onClose(); parentButton?.focus(); }
    if (event.key === 'Tab') { event.preventDefault(); onClose(); }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault(); setSubmenu(null);
      const buttons = [...ref.current!.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')];
      const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length;
      buttons[next]?.focus();
    }
  }}>{popup.quickActions && <><div className="menu-quick-actions">{popup.quickActions.map(item => <button key={item.label} role="menuitem" disabled={item.disabled} onClick={() => { onClose(); item.action?.(); }}><span className="menu-icon">{item.icon}</span><span>{item.label}</span></button>)}</div><div className="menu-divider"/></>}{popup.items.map((item, i) => <div key={i}>{item.divider && <div className="menu-divider"/>}<button role={item.radio ? 'menuitemradio' : item.checked !== undefined ? 'menuitemcheckbox' : 'menuitem'} aria-checked={item.checked} aria-haspopup={item.children ? 'menu' : undefined} aria-expanded={item.children ? submenu?.item === item : undefined} disabled={item.disabled} className={item.danger ? 'danger-item' : ''}
    onMouseEnter={event => { if (item.children) openSubmenu(item, event.currentTarget); else setSubmenu(null); }}
    onKeyDown={event => { if (item.children && event.key === 'ArrowRight') { event.preventDefault(); event.stopPropagation(); openSubmenu(item, event.currentTarget, true); } }}
    onClick={event => { if (item.children) openSubmenu(item, event.currentTarget, true); else { onClose(); item.action?.(); } }}>
    <span className="menu-mark">{item.checked && (item.radio ? <span className="menu-radio-dot"/> : <Check size={12}/>)}</span><span className="menu-icon">{item.icon}</span><span>{item.label}</span>{item.children ? <ChevronRight className="submenu-arrow" size={14}/> : <kbd>{item.shortcut}</kbd>}</button></div>)}</div>
    {submenu?.item.children && createPortal(<ContextMenu popup={{ x: 0, y: 0, items: submenu.item.children.map(item => ({ ...item, action: () => { onClose(); item.action?.(); } })) }} parentButton={submenu.button} label={submenu.item.label} onClose={() => setSubmenu(null)}/>, document.body)}
  </>;
}

function InlineName({ name, directory, onSave, onCancel }: { name: string; directory: boolean; onSave: (value: string) => void; onCancel: () => void }) {
  const [value, setValue] = useState(name); const ref = useRef<HTMLInputElement>(null); const canceled = useRef(false);
  useEffect(() => { ref.current?.focus(); ref.current?.setSelectionRange(0, !directory && name.lastIndexOf('.') > 0 ? name.lastIndexOf('.') : name.length); }, []);
  return <input className="inline-name" ref={ref} aria-label="名称" value={value} onChange={event => setValue(event.target.value)} onClick={event => event.stopPropagation()} onDoubleClick={event => event.stopPropagation()} onBlur={() => { if (!canceled.current) onSave(value); }} onKeyDown={event => {
    event.stopPropagation();
    if (event.key === 'Enter') { event.preventDefault(); onSave(value); }
    if (event.key === 'Escape') { event.preventDefault(); canceled.current = true; onCancel(); }
  }}/>;
}

function NavigationTree({ place, location, hidden, navigate, newTab, drop, context, pinned = false, level = 0 }: {
  place: Place; location: string; hidden: boolean; navigate: (path: string) => void; newTab: (path: string) => void;
  drop: (event: React.DragEvent, path: string) => void; context: (event: MouseEvent, place: Place) => void; pinned?: boolean; level?: number;
}) {
  const [expanded, setExpanded] = useState(false); const [children, setChildren] = useState<FileEntry[]>([]); const [loading, setLoading] = useState(false); const [error, setError] = useState(''); const [over, setOver] = useState(false);
  useEffect(() => {
    if (!expanded) return;
    let live = true; setLoading(true); setError('');
    api.list(place.path).then(result => { if (live) setChildren(result.entries.filter(e => e.isDirectory && !e.isSymlink && !e.name.endsWith('.app') && (hidden || !e.hidden)).sort((a, b) => a.name.localeCompare(b.name, 'zh-CN', { numeric: true }))); }).catch(e => { if (live) setError(errorMessage(e)); }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [expanded, place.path, hidden, location]);
  return <div className="tree-node">
    <div className={`tree-row ${location === place.path ? 'current' : ''} ${over ? 'drop-target' : ''}`} onDragOver={event => { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; setOver(true); }} onDragLeave={() => setOver(false)} onDrop={event => { setOver(false); drop(event, place.path); }}>
      <button className="tree-toggle" style={{ left: 1 + level * 12 }} aria-label={`${expanded ? '折叠' : '展开'} ${place.name}`} aria-expanded={expanded} onClick={() => setExpanded(v => !v)}>{loading ? <Loader2 size={11} className="spinning"/> : expanded ? <ChevronDown size={11}/> : <ChevronRight size={11}/>}</button>
      <button className={`nav-item ${location === place.path ? 'current' : ''}`} style={{ paddingLeft: 24 + level * 12 }} onClick={() => navigate(place.path)} onAuxClick={event => { if (event.button === 1) newTab(place.path); }} onContextMenu={event => context(event, place)}>
        {place.icon === 'folder' ? <FolderGlyph dimension={20}/> : <PlaceIcon icon={place.icon}/>}<span>{place.name}</span>{pinned && <Pin size={12} className="pin-mark"/>}
      </button>
    </div>
    {expanded && <div role="group" aria-label={`${place.name} 的子文件夹`}>{error ? <p className="tree-note" title={error}>无法访问</p> : !loading && !children.length ? <p className="tree-note">没有子文件夹</p> : children.map(child => <NavigationTree key={child.path} place={{ path: child.path, name: child.name, icon: 'folder' }} location={location} hidden={hidden} navigate={navigate} newTab={newTab} drop={drop} context={context} level={Math.min(level + 1, 6)}/>)}</div>}
  </div>;
}
function ModalDialog({ modal, value, onChange, error, busy, onClose, onSubmit }: { modal: Exclude<Modal, { kind: 'archive' }>; value: string; onChange: (value: string) => void; error: string; busy: boolean; onClose: () => void; onSubmit: () => void }) {
  const dialogRef = useRef<HTMLDialogElement>(null); const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    dialogRef.current?.showModal();
    const input = inputRef.current;
    if (input) { input.focus(); const dot = value.lastIndexOf('.'); input.setSelectionRange(0, modal.kind === 'rename' && dot > 0 ? dot : value.length); }
  }, []);
  const title = modal.kind === 'trash' ? '移到废纸篓' : modal.kind === 'rename' ? '重命名' : modal.kind === 'folder' ? '新建文件夹' : modal.kind === 'file' ? '新建文本文档' : '键盘快捷键';
  return <dialog ref={dialogRef} className={`modal ${modal.kind === 'shortcuts' ? 'shortcut-modal' : ''}`} aria-labelledby="modal-title" onCancel={event => { event.preventDefault(); onClose(); }} onClose={onClose}>
    <form onSubmit={event => { event.preventDefault(); onSubmit(); }}><div className="modal-heading"><h2 id="modal-title">{title}</h2><button type="button" aria-label="关闭对话框" onClick={onClose} disabled={busy}><X size={18}/></button></div>
      {modal.kind === 'shortcuts' ? <><p className="shortcut-note">Ctrl 快捷键也可以使用 Mac 的 ⌘ Command。</p><div className="shortcut-list">{[['复制 / 剪切 / 粘贴', 'Ctrl+C / X / V'], ['全选', 'Ctrl+A'], ['新建文件夹', 'Ctrl+Shift+N'], ['重命名', 'F2'], ['移到废纸篓', 'Delete / ⌘⌫'], ['打开项目', 'Enter'], ['快速查看', 'Space'], ['后退 / 前进 / 上一级', 'Alt+← / → / ↑'], ['编辑地址', 'Ctrl+L / Alt+D'], ['搜索', 'Ctrl+F'], ['刷新', 'F5'], ['新建 / 关闭标签页', 'Ctrl+T / W'], ['切换标签页', 'Ctrl+Tab'], ['属性窗格', 'Alt+Enter / ⌘I']].map(([name, keys]) => <div key={name}><span>{name}</span><kbd>{keys}</kbd></div>)}</div><p className="shortcut-note">F2 / F5 在部分 Mac 键盘上需要同时按住 Fn。拖放文件默认复制，移动请使用剪切和粘贴。</p></> : modal.kind === 'trash' ? <div className="trash-description"><Trash2 size={34} strokeWidth={1.4}/><div><p>将{modal.paths.length === 1 ? `“${base(modal.paths[0])}”` : `这 ${modal.paths.length} 个项目`}移到废纸篓？</p><small>文件将移入 macOS 废纸篓，你可以从那里恢复。</small></div></div> : <><label className="name-label" htmlFor="entry-name">名称</label><input ref={inputRef} id="entry-name" value={value} onChange={event => onChange(event.target.value)} disabled={busy} autoComplete="off"/><p className="modal-location">位置：{modal.kind === 'rename' ? parent(modal.path) : modal.path}</p></>}
      {error && <p className="modal-error" role="alert">{error}</p>}
      <div className="modal-actions"><button type="button" className="secondary-button" disabled={busy} onClick={onClose}>{modal.kind === 'shortcuts' ? '知道了' : '取消'}</button>{modal.kind !== 'shortcuts' && <button type="submit" className="primary-button" disabled={busy || modal.kind !== 'trash' && !value.trim()}>{busy ? '正在处理…' : modal.kind === 'trash' ? '移到废纸篓' : '确定'}</button>}</div>
    </form>
  </dialog>;
}
