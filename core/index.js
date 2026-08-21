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
  // WeChat ClawBot transport (SDK or OpenClaw HTTP backing)
  ...require('./lib/weixin-clawbot-transport'),
  // Channel account/token persistence (~/.dsh/channels/<id>.json, file-first)
  ...require('./lib/channel-store'),
  // Channel slash commands (docs/channel-ui-commands.md §4)
  ...require('./lib/channel-commands'),
  // Channel session mapping + message log (project .dsh, decision E)
  ...require('./lib/channel-sessions'),
  // Channel end-to-end runner (token->adapter->manager->session->reply)
  ...require('./lib/channel-runner'),
};
