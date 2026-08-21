'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { assignCodes, parseTag, resolveWorkspaceTag } = require('../lib/channel-workspaces');

const ws = [
  { workspaceId: 'a', path: '/Users/loie/repo/bravo' },
  { workspaceId: 'b', path: '/Users/loie/repo/alpha' },
  { workspaceId: 'c', path: '/Users/loie/repo/charlie' },
];

test('workspaces: assignCodes sorts by path and assigns w1/w2/w3', () => {
  const coded = assignCodes(ws);
  assert.equal(coded[0].path, '/Users/loie/repo/alpha');
  assert.equal(coded[0].code, 'w1');
  assert.equal(coded[1].code, 'w2');
  assert.equal(coded[2].code, 'w3');
});

test('workspaces: parseTag extracts #w1 and #name', () => {
  assert.deepEqual(parseTag('帮我看看 #w2 这个项目'), { raw: '#w2', value: 'w2' });
  assert.deepEqual(parseTag('/new #w1，开始和我对话'), { raw: '#w1', value: 'w1' });
  assert.equal(parseTag('普通消息没有 tag'), null);
});

test('workspaces: resolveWorkspaceTag routes by code #w1', () => {
  const r = resolveWorkspaceTag('请 #w1 处理', { workspaces: ws });
  assert.equal(r.source, 'tag');
  assert.equal(r.code, 'w1');
  assert.equal(r.workspace.path, '/Users/loie/repo/alpha');
  assert.equal(r.cleanText, '请 处理');  // tag stripped
});

test('workspaces: resolveWorkspaceTag matches by name/path fragment', () => {
  const r = resolveWorkspaceTag('看看 #bravo 的进度', { workspaces: ws });
  assert.equal(r.source, 'tag');
  assert.equal(r.code, 'w2');  // bravo path sorts 2nd -> w2
});

test('workspaces: no tag -> last workspace code', () => {
  const r = resolveWorkspaceTag('继续对话', { workspaces: ws, lastCode: 'w2' });
  assert.equal(r.source, 'last');
  assert.equal(r.code, 'w2');
});

test('workspaces: no tag, no last -> first workspace', () => {
  const r = resolveWorkspaceTag('开始吧', { workspaces: ws });
  assert.equal(r.source, 'first');
  assert.equal(r.code, 'w1');
});

test('workspaces: no workspaces -> source none', () => {
  const r = resolveWorkspaceTag('hi', { workspaces: [] });
  assert.equal(r.source, 'none');
  assert.equal(r.workspace, null);
});

test('workspaces: case-insensitive #W1', () => {
  const r = resolveWorkspaceTag('处理 #W2', { workspaces: ws });
  assert.equal(r.code, 'w2');
});
