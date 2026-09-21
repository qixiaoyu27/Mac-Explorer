import { t as tr } from './i18n';
export function isArchive(filePath: string) {
  return /\.(zip|zipx|7z|rar|tar|tgz|tbz2?|txz|gz|bz2|xz)$/i.test(filePath);
}
export function archiveFolderName(name: string) {
  return name.replace(/(?:\.tar)?\.(zip|zipx|7z|rar|tar|tgz|tbz2?|txz|gz|bz2|xz)$/i, '') || tr('解压文件');
}
