'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { createDingTalkAuth } = require('../lib/dingtalk-access');

function tmp() { return fs.mkdtempSync(path.join(os.tmpdir(), 'dt-auth-')); }

test('dingtalk-access: unbound rejects non-bind; /bind with code binds owner', async () => {
  const home = tmp();
  const auth = createDingTalkAuth({ channelId: 'dt-a', dshHome: home });
  assert.equal(auth.isBound(), false);
  const code = auth.getBindCode();
  assert.ok(code && code.length === 8);

  // unbound, non-bind message -> rejected
  const r1 = await auth.check({ sender: 'u1', text: 'hello' });
  assert.equal(r1.handled, false);
  assert.equal(r1.allowed, false);
  assert.match(r1.reply, /绑定管理员/);

  // wrong code -> rejected
  const r2 = await auth.check({ sender: 'u1', text: '/bind WRONG' });
  assert.equal(r2.handled, true);
  assert.equal(r2.allowed, false);

  // correct code -> bound to sender
  const r3 = await auth.check({ sender: 'u1', text: '/bind ' + code });
  assert.equal(r3.handled, true);
  assert.equal(r3.allowed, true);
  assert.match(r3.reply, /绑定成功/);
  assert.equal(auth.isBound(), true);
  assert.equal(auth.ownerStaffId(), 'u1');
});

test('dingtalk-access: after bind, owner allowed, others rejected', async () => {
  const home = tmp();
  const auth = createDingTalkAuth({ channelId: 'dt-b', dshHome: home });
  const code = auth.getBindCode();
  await auth.check({ sender: 'owner1', text: '/bind ' + code });

  const ok = await auth.check({ sender: 'owner1', text: 'run tests' });
  assert.equal(ok.handled, false);
  assert.equal(ok.allowed, true);

  const nope = await auth.check({ sender: 'intruder', text: 'run tests' });
  assert.equal(nope.handled, false);
  assert.equal(nope.allowed, false);
  assert.match(nope.reply, /无权限/);

  // owner rebinding is idempotent
  const again = await auth.check({ sender: 'owner1', text: '/bind ' + code });
  assert.equal(again.handled, true);
  assert.match(again.reply, /已是本通道管理员/);
});

test('dingtalk-access: binding persists across auth instances (same channel)', () => {
  const home = tmp();
  const a1 = createDingTalkAuth({ channelId: 'dt-c', dshHome: home });
  const code = a1.getBindCode();
  a1.check({ sender: 'owner', text: '/bind ' + code });
  // fresh instance reads the same binding file
  const a2 = createDingTalkAuth({ channelId: 'dt-c', dshHome: home });
  assert.equal(a2.isBound(), true);
  assert.equal(a2.ownerStaffId(), 'owner');
  assert.equal(a2.getBindCode(), code, 'bind code stable');
});
