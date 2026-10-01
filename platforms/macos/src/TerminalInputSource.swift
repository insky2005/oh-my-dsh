//
//  TerminalInputSource.swift — Keyboard input-source (IME) policy for the
//  integrated terminal.
//
//  A terminal wants a Latin keyboard: when it takes focus we switch to an
//  ASCII-capable input source (so a Chinese/Japanese IME does not intercept the
//  first keystrokes) and remember what the user had; when focus leaves we put
//  their original input source back. The user may still switch to a Chinese IME
//  mid-session — the policy never re-asserts English until focus leaves and
//  returns.
//
//  The invariant that matters most is that the remembered "original" is never
//  overwritten by the forced English: `savedID` is written exactly once per
//  focus cycle and only cleared once the original is back (or was never moved).
//  A repeated focus (e.g. hover-to-focus followed by a click) therefore can not
//  clobber it. The policy is a pure state machine over
//  `InputSourceControlling` so it can be unit-tested headlessly; the
//  Carbon-backed implementation is the only part that touches the system.
//

import Carbon
import Foundation

/// The slice of the system input-source API the terminal policy needs. Split
/// out so `tests/terminal-panel` can drive it with a fake.
protocol InputSourceControlling: AnyObject {
    /// Stable identifier of the currently selected keyboard input source.
    func currentInputSourceID() -> String?
    /// An ASCII-capable (English) keyboard input source, if the system has one.
    func asciiInputSourceID() -> String?
    /// Select the source identified by `id`; returns whether it was accepted.
    @discardableResult
    func selectInputSource(id: String) -> Bool
}

/// Focus/blur policy: remember the input source on focus, switch to English,
/// restore on blur.
///
/// The restore is **debounced**: moving focus around a terminal (or the input
/// source switch itself nudging the responder chain) can deliver a burst of
/// blur/focus pairs, and restoring on every blur made the input source flicker
/// several times. A blur only schedules a restore; a focus before the delay
/// elapses cancels it, so a burst collapses into a single switch and a single
/// (late) restore.
final class TerminalInputSourceGuard {

    /// The shared instance TerminalView talks to. Only one view can hold the
    /// keyboard at a time, so one save slot is enough.
    static let shared = TerminalInputSourceGuard(sources: TextInputSources())

    private let sources: InputSourceControlling
    private let restoreDelay: TimeInterval
    /// Schedules `body` after `delay`. Injectable so tests can run it inline.
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var savedID: String?
    /// Bumped on every focus; a scheduled restore whose generation no longer
    /// matches is stale and must not run.
    private var restoreGeneration = 0

    init(sources: InputSourceControlling,
         restoreDelay: TimeInterval = 0.12,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
         }) {
        self.sources = sources
        self.restoreDelay = restoreDelay
        self.schedule = schedule
    }

    /// Terminal became first responder: remember the user's input source and
    /// switch to English.
    func terminalDidFocus() {
        restoreGeneration += 1              // cancel any restore a blur scheduled
        // Write-once: while an original is remembered, a repeated focus must not
        // replace it with the English source we selected ourselves.
        guard savedID == nil else { return }
        guard let ascii = sources.asciiInputSourceID(),
              let current = sources.currentInputSourceID() else { return }
        // Already on English: nothing to remember and nothing to change, so a
        // later manual switch (to Chinese, say) is the user's to keep.
        guard current != ascii else { return }
        savedID = current
        sources.selectInputSource(id: ascii)
    }

    /// Terminal resigned first responder: schedule the remembered source to be
    /// put back. A focus before the delay elapses cancels it.
    func terminalDidBlur() {
        guard let saved = savedID else { return }
        let generation = restoreGeneration
        schedule(restoreDelay) { [weak self] in
            guard let self = self,
                  self.restoreGeneration == generation,
                  self.savedID == saved else { return }
            if self.sources.currentInputSourceID() == saved {
                self.savedID = nil                       // nothing moved
            } else if self.sources.selectInputSource(id: saved) {
                // Only forget the original once it is actually back. If the
                // system refuses the switch (secure input, IME not ready), keep
                // it so the next focus can not mistake the forced English for
                // the user's original.
                self.savedID = nil
            }
        }
    }

    /// Test hook: whether a pre-focus source is currently remembered.
    var hasSavedSource: Bool { savedID != nil }
}

/// Carbon-backed implementation of `InputSourceControlling`.
final class TextInputSources: InputSourceControlling {

    func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.identifier(of: source)
    }

    func asciiInputSourceID() -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return Self.identifier(of: source)
    }

    @discardableResult
    func selectInputSource(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func identifier(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String
    }
}
