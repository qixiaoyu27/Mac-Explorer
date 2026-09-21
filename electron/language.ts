import { app } from 'electron';
import fs from 'node:fs/promises';
import path from 'node:path';
import { isLanguageMode, resolveLocale, setLocale, t, type LanguageState, type LanguageMode } from '../shared/i18n';
let mode: LanguageMode = 'zh-CN';
export function languageState(): LanguageState {
  const preferred = process.env.EXPLORER_TEST_ROOT && process.env.EXPLORER_TEST_LOCALE ? [process.env.EXPLORER_TEST_LOCALE] : app.getPreferredSystemLanguages();
  const locale = resolveLocale(mode, preferred);
  setLocale(locale);
  return { mode, locale };
}
export async function loadLanguage() {
  try {
    const saved = JSON.parse(await fs.readFile(path.join(app.getPath('userData'), 'language.json'), 'utf8'));
    if (isLanguageMode(saved.mode)) mode = saved.mode;
  } catch { /* Preserve Chinese for existing installations until explicitly changed. */ }
  return languageState();
}
export async function saveLanguage(value: unknown) {
  if (!isLanguageMode(value)) throw new Error(t('无效的语言设置。'));
  const file = path.join(app.getPath('userData'), 'language.json');
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file + '.tmp', JSON.stringify({ mode: value }), 'utf8');
  await fs.rename(file + '.tmp', file);
  mode = value;
  return languageState();
}
