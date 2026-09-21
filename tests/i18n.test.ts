import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import en from '../shared/locales/en.json';
import tw from '../shared/locales/zh-TW.json';
import { isLanguageMode, resolveLocale, setLocale, t } from '../shared/i18n';

test('language resolution handles traditional regions, scripts and unsupported system languages', () => {
  for (const tag of ['zh-TW', 'zh-HK', 'zh-MO', 'zh-Hant', 'zh_Hant_HK']) assert.equal(resolveLocale('system', [tag]), 'zh-TW');
  for (const tag of ['zh-CN', 'zh-Hans', 'zh-SG']) assert.equal(resolveLocale('system', [tag]), 'zh-CN');
  for (const tag of ['en-US', 'fr-FR', 'ja-JP']) assert.equal(resolveLocale('system', [tag]), 'en');
  assert.equal(resolveLocale('system', ['en-US', 'zh-TW']), 'en');
  assert.equal(resolveLocale('zh-TW', ['en']), 'zh-TW');
  assert.equal(isLanguageMode('invalid'), false);
});
test('all extracted UI messages have English and Traditional Chinese with matching placeholders', () => {
  const files = ['src/App.tsx', ...fs.readdirSync('electron').filter(n => n.endsWith('.ts')).map(n => `electron/${n}`), 'shared/archives.ts'];
  const placeholders = (text: string) => [...text.matchAll(/\{\d+\}/g)].map(m => m[0]).sort();
  for (const file of files) {
    const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
    function visit(node: ts.Node) {
      if (ts.isCallExpression(node) && ['tr', 't'].includes(node.expression.getText(source)) && node.arguments[0] && ts.isStringLiteral(node.arguments[0])) {
        const key = node.arguments[0].text;
        for (const dictionary of [en, tw]) {
          const value = (dictionary as Record<string, string>)[key];
          assert.equal(typeof value, 'string', `${file}: Missing ${key}`);
          assert.deepEqual(placeholders(value), placeholders(key), key);
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(source);
  }
});
test('translations preserve interpolated filenames and pluralize counts', () => {
  setLocale('en');
  assert.equal(t('将“{0}”移到回收站？', '文件{0}.txt'), 'Move “文件{0}.txt” to the Recycle Bin?');
  assert.equal(t('{0} 个项目', 1), '1 item');
  assert.equal(t('{0} 个项目', 2), '2 items');
  setLocale('zh-TW'); assert.equal(t('回收站'), '資源回收筒');
  setLocale('zh-CN'); assert.equal(t('回收站'), '回收站');
});
