'use strict';

/**
 * core/lib/ports.js — port probe / free-port / service readiness.
 * Ported from src/main.swift (ServerManager) so any platform shell can reuse
 * the exact same "is dsh serving / is port free / find free port" semantics.
 */

const net = require('node:net');

/** True when nothing is listening on 127.0.0.1:port (mirror of isPortFree). */
function isPortFree(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const sock = net.connect({ port, host, timeout: 800 });
    let settled = false;
    const done = (free) => {
      if (!settled) { settled = true; sock.destroy(); resolve(free); }
    };
    sock.on('connect', () => done(false));   // something accepted → occupied
    sock.on('timeout', () => done(true));
    sock.on('error', () => done(true));      // ECONNREFUSED → free
  });
}

/** Ask the OS for any free TCP port on 127.0.0.1 (mirror of freePort). */
function freePort(host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, host, () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

/**
 * Pick the port to use: explicit override wins, else default (3080) if free,
 * else any free port. Mirrors ServerManager.start() step 2.
 */
async function pickPort(preferred = 3080, explicit = null) {
  if (explicit != null) return explicit;
  if (await isPortFree(preferred)) return preferred;
  return freePort();
}

/**
 * True when a dsh web UI is being served: GET / returns HTML containing the
 * `window.__DSH_BOOT__` marker the harness injects into its root page
 * (mirror of isDSHServing). Falls back to "any 2xx/3xx with a body".
 */
async function isDSHServing(port, host = '127.0.0.1', timeoutMs = 2000, needBootMarker = true) {
  const http = require('node:http');
  return new Promise((resolve) => {
    const req = http.get({ host, port, path: '/', timeout: timeoutMs }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; if (body.length > 200_000) { req.destroy(); resolve(false); } });
      res.on('end', () => {
        const ok = res.statusCode >= 200 && res.statusCode < 400;
        resolve(needBootMarker ? (ok && body.includes('__DSH_BOOT__')) : ok);
      });
    });
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
  });
}

module.exports = { isPortFree, freePort, pickPort, isDSHServing };
