// Regression tests for the shell's injected file-open interceptor
// (main.swift: previewInterceptorScript).
//
// dsh <= 0.1.4 opened a conversation file link through the host RPC
// host.openPath / session/openWorkspacePath, which the client sent via
// window.fetch. dsh >= 0.1.5 ships its own file panel and opens links entirely
// in-page (ctx.sidebarRight.openResource), so the shell had to start catching
// the CLICK instead. These tests pin both layers by evaluating the real script
// (extracted from main.swift, the single source of truth) against a tiny DOM
// stub, so a future dsh change that removes window.fetch or changes the link
// markup fails here instead of silently in the UI.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const MAIN_SWIFT = fileURLToPath(
  new URL('../../platforms/macos/src/main.swift', import.meta.url));

function extractSwiftString(source, name) {
  const marker = `private static let ${name} = """`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing ${name} in main.swift`);
  const from = start + marker.length;
  const end = source.indexOf('"""', from);
  assert.notEqual(end, -1, `unterminated ${name} in main.swift`);
  return source.slice(from, end);
}

// --- minimal DOM stubs ------------------------------------------------------

function matchesSelector(el, selector) {
  if (selector === 'code') return el.tagName === 'CODE';
  if (selector === 'button') return el.tagName === 'BUTTON';
  if (selector === 'button[title]') {
    return el.tagName === 'BUTTON' && el.getAttribute('title') !== null;
  }
  const attr = /^\[([^\]]+)\]$/.exec(selector);
  if (attr) return el.getAttribute(attr[1]) !== null;
  return false;
}

function makeElement({ tag, attrs = {}, parent = null, className = '' }) {
  const el = {
    tagName: tag.toUpperCase(),
    className,
    parentNode: parent,
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    closest(selector) {
      let node = el;
      while (node) {
        if (matchesSelector(node, selector)) return node;
        node = node.parentNode;
      }
      return null;
    },
  };
  return el;
}

function makeDocument() {
  const listeners = { click: [] };
  return {
    listeners,
    addEventListener(type, handler, capture) {
      (listeners[type] ||= []).push({ handler, capture });
    },
  };
}

function makeEvent(target) {
  return {
    target,
    defaultPrevented: false,
    propagationStopped: false,
    preventDefault() { this.defaultPrevented = true; },
    stopPropagation() { this.propagationStopped = true; },
    stopImmediatePropagation() { this.propagationStopped = true; },
  };
}

function dispatchClick(document, event) {
  for (const { handler } of document.listeners.click) handler(event);
}

function makeEnvironment() {
  const posted = [];
  const passedThrough = [];
  const window = {
    fetch: async (input) => {
      passedThrough.push(String(input));
      return new Response('orig', { status: 200 });
    },
    webkit: { messageHandlers: { dshPreview: { postMessage: (m) => posted.push(m) } } },
  };
  return { window, posted, passedThrough, document: makeDocument() };
}

const script = extractSwiftString(
  readFileSync(MAIN_SWIFT, 'utf8'), 'previewInterceptorScript');

function install() {
  const env = makeEnvironment();
  // The script is an IIFE; it patches window.fetch and registers the click
  // listener through document.addEventListener.
  new Function('window', 'document', script)(env.window, env.document);
  return env;
}

// --- layer 1: click capture (dsh >= 0.1.5) ---------------------------------

test('a produced-files chip click is posted and swallowed', () => {
  const env = install();
  const row = makeElement({ tag: 'div', attrs: { 'data-produced-files-row': '' } });
  const chip = makeElement({ tag: 'button', attrs: { title: '/tmp/produced.txt' }, parent: row });
  const event = makeEvent(chip);
  dispatchClick(env.document, event);
  assert.deepEqual(env.posted, [{ path: '/tmp/produced.txt', source: 'click' }]);
  assert.equal(event.defaultPrevented, true, 'default action must be prevented');
  assert.equal(event.propagationStopped, true, 'event must not reach dsh\'s own panel');
});

test('an inline mention click is posted and swallowed (relative path kept)', () => {
  const env = install();
  const code = makeElement({ tag: 'code' });
  const mention = makeElement({
    tag: 'button',
    attrs: { title: 'src/main.swift' },
    parent: code,
    className: '_fileMention_kcgor_304',
  });
  const event = makeEvent(mention);
  dispatchClick(env.document, event);
  assert.deepEqual(env.posted, [{ path: 'src/main.swift', source: 'click' }]);
  assert.equal(event.defaultPrevented, true);
  assert.equal(event.propagationStopped, true);
});

test('a mention is recognized by its <code> ancestor even without the class', () => {
  const env = install();
  const code = makeElement({ tag: 'code' });
  const mention = makeElement({ tag: 'button', attrs: { title: 'lib/index.js' }, parent: code });
  dispatchClick(env.document, makeEvent(mention));
  assert.equal(env.posted.length, 1);
  assert.equal(env.posted[0].path, 'lib/index.js');
});

test('an unrelated button with a path title is left alone', () => {
  const env = install();
  const treeRow = makeElement({ tag: 'button', attrs: { title: '/tmp/tree-file.txt' } });
  const event = makeEvent(treeRow);
  dispatchClick(env.document, event);
  assert.equal(env.posted.length, 0, 'file-tree rows must keep dsh behaviour');
  assert.equal(event.defaultPrevented, false);
  assert.equal(event.propagationStopped, false);
});

test('an icon (non-button) target resolves to its file-link button', () => {
  const env = install();
  const row = makeElement({ tag: 'div', attrs: { 'data-produced-files-row': '' } });
  const chip = makeElement({ tag: 'button', attrs: { title: '/tmp/icon.txt' }, parent: row });
  const icon = makeElement({ tag: 'svg', parent: chip });
  dispatchClick(env.document, makeEvent(icon));
  assert.equal(env.posted.length, 1);
  assert.equal(env.posted[0].path, '/tmp/icon.txt');
});

// --- layer 2: legacy host-RPC fetch interception ---------------------------

test('the modern session/openWorkspacePath shape is swallowed with a fake success', async () => {
  const env = install();
  const response = await env.window.fetch('/api/session/openWorkspacePath', {
    method: 'POST',
    body: JSON.stringify({
      type: 'client-request',
      rpcId: 'rpc-1',
      method: 'session/openWorkspacePath',
      payload: { args: { request: { path: '/tmp/legacy.txt' } } },
    }),
  });
  assert.equal(env.window.__dshPreviewHit, '/tmp/legacy.txt');
  assert.deepEqual(env.posted, [{ path: '/tmp/legacy.txt' }]);
  const json = await response.json();
  assert.equal(json.type, 'server-response');
  assert.equal(json.rpcId, 'rpc-1');
  assert.deepEqual(json.result, { ok: true, value: { opened: true } });
  assert.equal(env.passedThrough.length, 0, 'the request must not reach the server');
});

test('the legacy host.openPath shape (payload.path) is still recognized', async () => {
  const env = install();
  await env.window.fetch('/api/host.openPath', {
    method: 'POST',
    body: JSON.stringify({
      type: 'client-request',
      rpcId: 'rpc-2',
      method: 'host.openPath',
      payload: { path: '/tmp/old.txt' },
    }),
  });
  assert.equal(env.window.__dshPreviewHit, '/tmp/old.txt');
  assert.equal(env.passedThrough.length, 0);
});

test('unrelated fetches pass through untouched', async () => {
  const env = install();
  await env.window.fetch('/api/session/list', { method: 'POST', body: '{}' });
  assert.deepEqual(env.passedThrough, ['/api/session/list']);
});
