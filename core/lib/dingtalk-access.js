'use strict';

/**
 * core/lib/dingtalk-access.js — DingTalk owner-binding access control.
 *
 * Security gate for the DingTalk channel: before the bound owner is set, the bot
 * rejects everyone; the owner binds via /bind <one-time-code>. After binding, only
 * the owner staffId is authorized (the safe default). This prevents ANY org member
 * who can reach the bot from driving the local dsh agent (bash/files/tokens).
 *
 * Persisted in ~/.dsh/channels/<channelId>.binding.json (ownerStaffId + one-time code).
 *
 *   const { createDingTalkAuth } = require('@oh-my-dsh/core');
 *   const auth = createDingTalkAuth({ channelId, dshHome });
 *   const a = await auth.check(event); // { handled, allowed, reply? }
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { helpText } = require('./channel-commands');

function channelsDir(dshHome) {
  return path.join(dshHome || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'), 'channels');
}

function bindingFile(channelId, dshHome) {
  return path.join(channelsDir(dshHome), channelId + '.binding.json');
}

/** 8 unambiguous uppercase alphanumerics (no 0/O/1/I/l). */
function generateBindCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.randomBytes(8);
  let code = '';
  for (let i = 0; i < 8; i++) code += alphabet[bytes[i] % alphabet.length];
  return code;
}

function loadBinding(channelId, dshHome) {
  try {
    const p = bindingFile(channelId, dshHome);
    if (!fs.existsSync(p)) return { ownerStaffId: null, bindCode: null };
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    return { ownerStaffId: data.ownerStaffId || null, bindCode: data.bindCode || null };
  } catch { return { ownerStaffId: null, bindCode: null }; }
}

function saveBinding(channelId, binding, dshHome) {
  try {
    const p = bindingFile(channelId, dshHome);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify({ version: 1, ...binding, updatedAt: Date.now() }, null, 2), { mode: 0o600 });
  } catch { /* non-fatal */ }
}

function createDingTalkAuth(opts = {}) {
  const channelId = opts.channelId;
  const dshHome = opts.dshHome;
  const log = opts.log || (() => {});
  if (!channelId) throw new Error('dingtalk-access: channelId required');

  let state = loadBinding(channelId, dshHome);
  if (!state.bindCode) {
    state = { ownerStaffId: state.ownerStaffId || null, bindCode: generateBindCode() };
    saveBinding(channelId, state, dshHome);
  }

  function isBound() { return loadBinding(channelId, dshHome).ownerStaffId != null; }
  function ownerStaffId() { return loadBinding(channelId, dshHome).ownerStaffId; }
  function getBindCode() { return loadBinding(channelId, dshHome).bindCode; }

  // Serialize /bind attempts so only the FIRST sender with the correct code binds;
  // a concurrent duplicate cannot read a stale "not bound" and overwrite the owner.
  let bindLock = Promise.resolve();
  function withBindLock(fn) {
    const run = bindLock.then(() => fn());
    bindLock = run.catch(() => {}); // keep the chain always-resolved
    return run;
  }
  async function bindCommand(sender, bindMatch) {
    const cur = loadBinding(channelId, dshHome);
    if (cur.ownerStaffId != null) {
      if (sender === cur.ownerStaffId) {
        return { handled: true, allowed: true, reply: '你已是本通道管理员。' };
      }
      return { handled: true, allowed: false, reply: '该通道已绑定管理员，无权重新绑定。' };
    }
    const code = bindMatch[1] || '';
    if (!code) {
      return { handled: true, allowed: true, reply: '请发送：/bind <口令>（口令在本机生成，见面板或运行日志）' };
    }
    if (code.toUpperCase() !== cur.bindCode) {
      return { handled: true, allowed: false, reply: '绑定口令错误。' };
    }
    saveBinding(channelId, { ownerStaffId: sender, bindCode: cur.bindCode }, dshHome);
    log('[dingtalk:' + channelId + '] owner bound: ' + sender);
    return {
      handled: true,
      allowed: true,
      reply: ['绑定成功，你已被设为该通道管理员。', '可用指令：\n' + helpText()],
    };
  }

  /**
   * Check an inbound event. Returns { handled, allowed, reply? }.
   *  - handled=true:  a /bind command was consumed (reply is the response).
   *  - handled=false, allowed=true:  proceed to route.
   *  - handled=false, allowed=false: reject (reply is the rejection message).
   */
  async function check(event) {
    const sender = event && event.sender;
    const text = String(event && event.text || '').trim();
    const bindMatch = /^\/bind(?:\s+([A-Za-z0-9]+))?/i.exec(text);
    if (bindMatch) {
      return withBindLock(() => bindCommand(sender, bindMatch));
    }
    const cur = loadBinding(channelId, dshHome);
    if (cur.ownerStaffId == null) {
      return { handled: false, allowed: false, reply: '该通道尚未绑定管理员。请先发送 /bind <口令>（口令在本机生成）。' };
    }
    if (sender !== cur.ownerStaffId) {
      return { handled: false, allowed: false, reply: '无权限：仅管理员可使用该通道。' };
    }
    return { handled: false, allowed: true };
  }

  return { check, isBound, ownerStaffId, getBindCode, bindingFile: bindingFile(channelId, dshHome) };
}

module.exports = { createDingTalkAuth, generateBindCode, bindingFile };