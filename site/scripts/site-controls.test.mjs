import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';

const site = new URL('../', import.meta.url);
const controls = ts.transpileModule(readFileSync(new URL('src/scripts/site-controls.ts', site), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None },
}).outputText;

function runControls(storage) {
  const root = { dataset: { theme: 'light', lang: 'zh' }, lang: 'zh-CN' };
  const listeners = new Map();
  const localized = {
    dataset: { ariaLabelEn: 'Open in MacTools', ariaLabelZh: '在 MacTools 中打开' },
    setAttribute(key, value) { this[key] = value; },
  };
  runInNewContext(controls, {
    document: {
      documentElement: root,
      querySelector: (selector) => ({ addEventListener: (_, callback) => listeners.set(selector, callback) }),
      querySelectorAll: (selector) => selector === '[data-aria-label-zh][data-aria-label-en]' ? [localized] : [],
    },
    window: { matchMedia: () => ({ matches: false }) },
    navigator: { languages: ['en-US'] },
    localStorage: storage,
    MutationObserver: class { observe() {} },
  });
  return { root, listeners, localized };
}

test('theme and language toggle once and persist across page loads', () => {
  const values = new Map();
  const storage = { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) };
  const first = runControls(storage);
  assert.equal(first.root.lang, 'en');
  assert.equal(first.localized['aria-label'], 'Open in MacTools');
  first.listeners.get('[data-theme-toggle]')();
  first.listeners.get('[data-language-toggle]')();
  assert.equal(first.root.dataset.theme, 'dark');
  assert.equal(first.root.lang, 'zh-CN');
  const next = runControls(storage);
  assert.equal(next.root.dataset.theme, 'dark');
  assert.equal(next.root.lang, 'zh-CN');
  assert.equal(next.localized['aria-label'], '在 MacTools 中打开');
});

test('unavailable storage does not prevent controls from working', () => {
  const blocked = () => { throw new Error('Storage blocked'); };
  const { root, listeners } = runControls({ getItem: blocked, setItem: blocked });
  listeners.get('[data-theme-toggle]')();
  listeners.get('[data-language-toggle]')();
  assert.equal(root.dataset.theme, 'dark');
  assert.equal(root.lang, 'zh-CN');
});

function htmlFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? htmlFiles(path) : entry.name.endsWith('.html') ? [path] : [];
  });
}

test('every rendered navigation includes the same controls bundle exactly once', () => {
  const dist = new URL('dist/', site);
  const controlScripts = (html) => [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)]
    .map(([, attributes, contents]) => {
      const src = attributes.match(/src="([^"]+)"/)?.[1];
      return src ? readFileSync(new URL(src.replace(/^\//, ''), dist), 'utf8') : contents;
    }).filter((script) => script.includes('data-theme-toggle'));
  const home = readFileSync(new URL('index.html', dist), 'utf8');
  const sharedControls = controlScripts(home);
  assert.equal(sharedControls.length, 1);
  let checked = 0;
  for (const path of htmlFiles(fileURLToPath(dist))) {
    const html = readFileSync(path, 'utf8');
    if (!html.includes('data-theme-toggle')) continue;
    assert.deepEqual(controlScripts(html), sharedControls, path);
    checked++;
  }
  assert.ok(checked > 100, 'include generated plugin and action pages');
});

test('Fan Control retains its preset and speed slider preview', () => {
  const html = readFileSync(new URL('dist/plugins/index.html', site), 'utf8');
  const panel = html.split('data-settings-panel="fan-control"')[1]?.split('<section class="settings-panel ')[0];
  assert.ok(panel);
  assert.match(panel, /Full speed/);
  assert.match(panel, /Quiet work/);
  assert.match(panel, /type="range"/);
  assert.match(panel, /6800/);
});
