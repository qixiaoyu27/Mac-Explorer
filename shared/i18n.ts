import en from './locales/en.json';
import traditional from './locales/zh-TW.json';

export type Locale = 'zh-CN' | 'zh-TW' | 'en';
export type LanguageMode = Locale | 'system';
export interface LanguageState { mode: LanguageMode; locale: Locale }
const dictionaries: Record<string, Record<string, string>> = { en, 'zh-TW': traditional };
let locale: Locale = 'zh-CN';
export function isLanguageMode(value: unknown): value is LanguageMode {
  return value === 'system' || value === 'zh-CN' || value === 'zh-TW' || value === 'en';
}
export function resolveLocale(mode: LanguageMode, preferred: readonly string[]): Locale {
  if (mode !== 'system') return mode;
  const first = (preferred[0] || 'en').replaceAll('_', '-').toLowerCase();
  if (!first.startsWith('zh')) return 'en';
  return /hant|(?:^|-)(tw|hk|mo)(?:-|$)/.test(first) ? 'zh-TW' : 'zh-CN';
}
export function setLocale(next: Locale) { locale = next; }
export function getLocale() { return locale; }
export function t(key: string, ...values: unknown[]): string {
  const singular: Record<string, string> = {
    '{0} 个项目': '{0} item', '{0} 个驱动器': '{0} drive', '{0} 个匹配项目': '{0} match',
    '已选择 {0} 个项目': '{0} item selected', '{0} 个位置无法访问': '{0} location could not be accessed',
    '{0} 个项目 · 同名项目会跳过，不覆盖': '{0} item · Existing items will be skipped, not overwritten',
    '永久删除回收站中的 {0} 个项目？': 'Permanently delete {0} item from the Recycle Bin?',
  };
  let template = locale === 'en' && values[0] === 1 && singular[key] ? singular[key] : dictionaries[locale]?.[key] ?? key;
  if (locale === 'en' && values[1] === 1 && (key === '{0} {1} 个项目' || key === '已{0} {1} 个项目，请到目标文件夹粘贴')) template = template.replace('items', 'item');
  return template.replace(/\{(\d+)\}/g, (match, index) => Number(index) < values.length ? String(values[Number(index)]) : match);
}
