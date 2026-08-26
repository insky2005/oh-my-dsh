'use strict';

/**
 * @oh-my-dsh/core — oh-my-dsh shared core (platform-independent Node module).
 *
 * Extracted from the macOS shell (src/*.swift) so Windows/Linux shells reuse
 * the exact same logic: ANSI terminal emulator, port/service management,
 * dsh upgrade and session RPC.
 *
 *   const { TerminalEmulator } = require('@oh-my-dsh/core');
 *   const { isDSHServing } = require('@oh-my-dsh/core');
 */

module.exports = {
  // ANSI terminal emulator (ported from TerminalPanel.swift)
  TerminalEmulator: require('./lib/ansi').TerminalEmulator,
  // Port probe / free port / service readiness (ported from main.swift ServerManager)
  ...require('./lib/ports'),
  // Version compare / registry / upgrade helpers (ported from VersionKit/RegistryConfig/DSHUpdater)
  ...require('./lib/upgrade'),
  // dsh web session RPC (ported from DSHSessionRPC)
  ...require('./lib/session'),
  // GitHub issues & PR integration (IssueRunner panel)
  ...require('./lib/issues'),
  // Serial job queue state machine (IssueRunner + future remote drivers)
  ...require('./lib/jobqueue'),
  // Issue-task association index (.dsh/tasks/ persistence)
  ...require('./lib/tasks'),
  // Channel capability: unified abstraction (event/reply/state/router/config)
  ...require('./lib/channel'),
  // Channel session driver (create/prompt/cancel/poll a dsh session from a message)
  ...require('./lib/session-driver'),
  // WeChat ClawBot channel adapter (first ChannelAdapter implementation)
  ...require('./lib/weixin-clawbot'),
  // DingTalk channel adapter (Stream push transport)
  ...require('./lib/dingtalk'),
  // DingTalk Stream transport (built-in WebSocket/fetch)
  ...require('./lib/dingtalk-stream-transport'),
  // DingTalk device-code app registration (QR auto-create)
  ...require('./lib/dingtalk-device'),
  // DingTalk owner-binding access control (/bind)
  ...require('./lib/dingtalk-access'),
  // WeChat ClawBot transport (SDK or OpenClaw HTTP backing)
  ...require('./lib/weixin-clawbot-transport'),
  // Channel account/token persistence (~/.dsh/channels/<id>.json, file-first)
  ...require('./lib/channel-store'),
  // Channel slash commands (docs/channel-ui-commands.md §4)
  ...require('./lib/channel-commands'),
  // Channel workspace codes / #tag routing
  ...require('./lib/channel-workspaces'),
  // Channel channel-scoped session mapping + bucketed message log (global ~/.dsh/channels)
  ...require('./lib/channel-sessions'),
  // Channel end-to-end runner (token->adapter->manager->session->reply)
  ...require('./lib/channel-runner'),
};
