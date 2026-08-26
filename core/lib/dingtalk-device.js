'use strict';

/**
 * core/lib/dingtalk-device.js — DingTalk device-code app registration.
 *
 * Reuses the open-platform device-code flow (init/begin/poll) to auto-create a
 * DingTalk app + robot by scanning a QR (docs/channel-dingtalk-stream.md §4).
 * The endpoint accepts any source; source is an optional attribution tag.
 *
 *   const { beginRegistration, waitForCredentials } = require('@oh-my-dsh/core');
 */

const BASE = () => process.env.DINGTALK_REGISTRATION_BASE_URL || 'https://oapi.dingtalk.com';
const SOURCE = () => process.env.DINGTALK_REGISTRATION_SOURCE || 'DING_DSH';

function withSource(uri, source) {
  const url = new URL(uri);
  url.searchParams.set('source', source);
  return url.toString();
}

async function post(pathname, body) {
  const fetchImpl = globalThis.fetch;
  if (!fetchImpl) throw new Error('dingtalk-device: no fetch available');
  const res = await fetchImpl(BASE() + pathname, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error('dingtalk-device: HTTP ' + res.status + ': ' + (await res.text()).slice(0, 200));
  const data = await res.json();
  if (!data || data.errcode !== 0) throw new Error('dingtalk-device: ' + (data && data.errmsg || 'unknown') + ' (errcode=' + (data && data.errcode) + ')');
  return data;
}

/** Start registration: returns { deviceCode, verificationUriComplete, expiresInSeconds, intervalSeconds }. */
async function beginRegistration() {
  const source = SOURCE();
  const init = await post('/app/registration/init', { source });
  const nonce = String(init && init.nonce || '').trim();
  if (!nonce) throw new Error('dingtalk-device: [init] missing nonce');
  const begin = await post('/app/registration/begin', { nonce });
  const deviceCode = String(begin && begin.device_code || '').trim();
  const verificationUri = String(begin && begin.verification_uri_complete || '').trim();
  if (!deviceCode || !verificationUri) throw new Error('dingtalk-device: [begin] missing device_code/verification_uri_complete');
  return {
    deviceCode,
    verificationUriComplete: withSource(verificationUri, source),
    expiresInSeconds: Number.isFinite(begin.expires_in) && begin.expires_in > 0 ? begin.expires_in : 7200,
    intervalSeconds: Number.isFinite(begin.interval) && begin.interval > 0 ? begin.interval : 5,
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Poll until scanned. Returns { clientId, clientSecret } on SUCCESS; throws on FAIL/EXPIRED/timeout.
 * Transient errors get a 2-minute retry window (mirrors the official flow).
 */
async function waitForCredentials(begin) {
  const RETRY_WINDOW_MS = 2 * 60_000;
  const startedAt = Date.now();
  let retryStart = 0;
  while (Date.now() - startedAt < begin.expiresInSeconds * 1000) {
    await sleep(begin.intervalSeconds * 1000);
    let polled;
    try {
      polled = await post('/app/registration/poll', { device_code: begin.deviceCode });
    } catch (err) {
      if (!retryStart) retryStart = Date.now();
      if (Date.now() - retryStart < RETRY_WINDOW_MS) continue;
      throw err;
    }
    const status = String(polled && polled.status || '').trim().toUpperCase();
    if (status === 'WAITING') { retryStart = 0; continue; }
    if (status === 'SUCCESS') {
      const clientId = String(polled.client_id || '').trim();
      const clientSecret = String(polled.client_secret || '').trim();
      if (!clientId || !clientSecret) throw new Error('dingtalk-device: SUCCESS but missing client_id/client_secret');
      return { clientId, clientSecret };
    }
    if (!retryStart) retryStart = Date.now();
    if (Date.now() - retryStart < RETRY_WINDOW_MS) continue;
    if (status === 'FAIL') throw new Error('dingtalk-device: authorization failed: ' + (polled.fail_reason || ''));
    if (status === 'EXPIRED') throw new Error('dingtalk-device: authorization expired, retry');
    throw new Error('dingtalk-device: unknown poll status ' + status);
  }
  throw new Error('dingtalk-device: authorization timeout');
}

module.exports = { beginRegistration, waitForCredentials, BASE, SOURCE };