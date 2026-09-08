export interface FileEntry {
  path: string; name: string; isDirectory: boolean; isSymlink: boolean;
  size: number; modified: number; created: number; extension: string; hidden: boolean;
}
export interface Place { path: string; name: string; icon: string }
export interface Volume extends Place { total: number; free: number }
export type ThemeMode = 'light' | 'dark' | 'system';
export interface Bootstrap { theme: ThemeMode; home: string; places: Place[]; volumes: Volume[]; initialPath?: string }
export interface Listing { path: string; entries: FileEntry[] }
export interface SearchResult { entries: FileEntry[]; truncated: boolean; skipped: number }
export interface FileChange { from?: string; to: string }
export interface OperationResult { succeeded: string[]; errors: { path: string; message: string }[]; changes?: FileChange[] }
export type ClipboardInfo = { paths: string[]; cut: boolean };
export type Preview = { kind: 'image' | 'text' | 'none'; content: string; truncated?: boolean };
export type ExtractMode = 'choose' | 'here' | 'folder';
export interface ArchivePreview { path: string; name: string; entries: { path: string; directory: boolean; size: number }[] }
export interface ExplorerAPI {
  bootstrap(): Promise<Bootstrap>;
  setTheme(mode: ThemeMode): Promise<ThemeMode>;
  list(path: string): Promise<Listing>;
  search(path: string, query: string, hidden: boolean): Promise<SearchResult>;
  cancelSearch(): Promise<void>;
  open(path: string): Promise<ArchivePreview | null>;
  compressArchive(paths: string[]): Promise<string>;
  openArchiveFile(path: string, member: string): Promise<void>;
  extractArchive(path: string, selected: string[] | null, mode: ExtractMode): Promise<OperationResult | null>;
  openWith(paths: string[]): Promise<boolean>;
  quickLook(path: string): Promise<void>;
  reveal(path: string): Promise<void>;
  openTerminal(path: string): Promise<void>;
  share(paths: string[]): Promise<void>;
  info(path: string): Promise<FileEntry>;
  preview(path: string): Promise<Preview>;
  icon(path: string, pixels?: number): Promise<string>;
  create(parent: string, name: string, directory: boolean): Promise<string>;
  rename(path: string, name: string): Promise<string>;
  trash(paths: string[]): Promise<OperationResult>;
  clipboardSet(paths: string[], cut: boolean): Promise<ClipboardInfo>;
  clipboardGet(): Promise<ClipboardInfo>;
  paste(parent: string): Promise<OperationResult>;
  copyTo(paths: string[], parent: string): Promise<OperationResult>;
  history(): Promise<string | null>;
  undo(): Promise<OperationResult>;
  copyText(text: string): Promise<void>;
  chooseFolder(): Promise<string | null>;
  filePath(file: File): string;
  watch(path: string | null): Promise<void>;
  onDirectoryChange(callback: () => void): () => void;
  onAction(callback: (action: string) => void): () => void;
}
