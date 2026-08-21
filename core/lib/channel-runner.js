'use strict';

/**
 * core/lib/channel-runner.js — run a live WeChat channel end-to-end.
 *
 * Wires the already-verified pieces into one loop (docs §6/§9):
 *   token(disk) -> ClawBot transport -> adapter (long-poll getupdates)
 *     -> ChannelManager (Router + SessionDriver against live dsh web)
 *     -> context_token reply via adapter.send
 *
 * This is the "run" half that the macOS panel / CLI invokes. Pure Node, so
 * Windows/Linux shells reuse it unchanged (docs §3.4).
 *
 *   const { runWeixinChannel } = require('@oh-my-dsh/core');
 *   const handle = runWeixinChannel({ channelId, port, refs, dshHome });
 *   await handle.start();
 *   ...
 *   await handle.stop();
 */

const { createWeixinClawBotTransport } = require('./weixin-clawbot-transport');
const { createWeixinClawBotAdapter } = require('./weixin-clawbot');
const { createSessionDriver } = require('./session-driver');
const { createChannelManager, normalizeEvent } = require('./channel');
const { loadChannelAccount, saveChannelAccount } = require('./channel-store');
const { createQueue } = require('./jobqueue');

/**
 * Build the adapters map for a set of project refs. Each distinct channelId in
 * refs gets a ClawBot adapter backed by its saved account token (if any).
 * Returns { adapters: Map, refsByChannel(channelId) }.
 */
function buildWeixinAdapters({ refs, dshHome, transportOpts, intervalMs }) {
  const adapters = new Map();
  const byChannel = new Map();
  for (const ref of refs || []) {
    if (!ref.channelId) continue;
    const list = byChannel.get(ref.channelId) || [];
    list.push(ref);
    byChannel.set(ref.channelId, list);
  }
  for (const [channelId, channelRefs] of byChannel) {
    const account = loadChannelAccount(channelId, dshHome);
    const transport = createWeixinClawBotTransport({
      channelId,
      token: account ? account.botToken : null,
      baseUrl: account ? account.baseUrl : undefined,
      ...(transportOpts || {}),
    });
    const adapter = createWeixinClawBotAdapter({ channelId, transport, intervalMs: intervalMs || 1000 });
    adapters.set(channelId, adapter);
  }
  const refsByChannel = (channelId) => byChannel.get(channelId) || [];
  return { adapters, refsByChannel };
}

/**
 * Run a live WeChat channel end-to-end.
 *
 * opts:
 *   channelId   - the global channel id whose saved token to use
 *   port        - dsh web port (default 3080)
 *   refs        - project refs for this channel (from .dsh/channels.json)
 *   dshHome     - DSH_HOME for token lookup (default ~/.dsh)
 *   sessionOpts - overrides for createSessionDriver (poll interval etc.)
 *   transportOpts - overrides for createWeixinClawBotTransport (fetch, baseUrl)
 *   intervalMs  - adapter long-poll interval
 *   onEvent     - optional callback(event, reply) after handling each message
 *   onState     - optional callback(channelId, state) on adapter state changes
 */
async function runWeixinChannel(opts = {}) {
  const channelId = opts.channelId;
  if (!channelId) throw new Error('channel-runner: channelId required');
  const { adapters, refsByChannel } = buildWeixinAdapters({
    refs: opts.refs || [],
    dshHome: opts.dshHome,
    transportOpts: opts.transportOpts,
    intervalMs: opts.intervalMs,
  });
  const adapter = adapters.get(channelId);
  if (!adapter) throw new Error('channel-runner: no adapter for ' + channelId);

  const sessionDriver = createSessionDriver({ port: opts.port || 3080, ...(opts.sessionOpts || {}) });
  const manager = createChannelManager({
    adapters,
    refsByChannel,
    sessionDriver,
    jobQueue: createQueue(),
  });

  let running = false;
  const onEventUnsub = adapter.onEvent(async (event) => {
    if (!running) return;
    try {
      const result = await manager.enqueue(event);
      if (opts.onEvent) opts.onEvent(event, result);
    } catch (e) {
      // isolation: a failed message must not kill the poll loop
    }
  });

  return {
    channelId,
    adapter,
    manager,
    async start() {
      running = true;
      await adapter.connect();
    },
    async stop() {
      running = false;
      onEventUnsub();
      await adapter.disconnect();
    },
    state: () => adapter.getState(),
    account: () => loadChannelAccount(channelId, opts.dshHome),
  };
}

module.exports = { runWeixinChannel, buildWeixinAdapters };
