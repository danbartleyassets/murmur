import Foundation

/// The trigger-key gesture, as a pure state machine with injected time so it can
/// be tested without a keyboard (`swift run murmur-check`).
///
///   double-tap, hold   → record while held, insert on release      (push-to-talk)
///   triple-tap         → record hands-free until the next tap       (locked)
///   tap while locked   → finish and insert
///
/// Recording starts on the *second* press so the first words are never lost.
/// If that second press turns out to be a quick tap, recording carries on for a
/// short window in case a third tap arrives (lock). No third tap means it was an
/// accidental double-tap, and the recording is discarded.
///
/// Any other key pressed during a tap sequence (Shift+A for a capital letter)
/// resets it, so ordinary typing can't trigger a recording.
public struct TapGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case startRecording
        case lock
        case finish          // stop and insert the transcript
        case discard         // stop and throw the audio away (accidental double-tap)
    }

    public enum State: Equatable, Sendable {
        case idle
        case firstDown(at: TimeInterval)
        case firstTapped(at: TimeInterval)
        case secondDown(at: TimeInterval)        // recording, push-to-talk or start of a triple
        case awaitingThird(at: TimeInterval)     // recording, second press was a tap
        case lockPressed                         // recording, third press still held
        case locked                              // recording, hands-free
        case lockedDown(at: TimeInterval)        // recording, trigger pressed while locked
        case lockedChord                         // recording, trigger used for a chord while locked
    }

    /// A press shorter than this is a tap.
    public var tapMax: TimeInterval
    /// Max gap between one tap's release and the next press.
    public var window: TimeInterval

    public private(set) var state: State = .idle

    public init(tapMax: TimeInterval = 0.3, window: TimeInterval = 0.4) {
        self.tapMax = tapMax
        self.window = window
    }

    /// Whether the machine believes a recording is in progress.
    public var isRecording: Bool {
        switch state {
        case .secondDown, .awaitingThird, .lockPressed, .locked, .lockedDown, .lockedChord: return true
        default: return false
        }
    }

    public var isLocked: Bool {
        switch state {
        case .lockPressed, .locked, .lockedDown, .lockedChord: return true
        default: return false
        }
    }

    /// When the host should call `tick(at:)` next, if a timeout is pending.
    public var deadline: TimeInterval? {
        switch state {
        case .firstTapped(let t), .awaitingThird(let t): return t + window
        default: return nil
        }
    }

    // MARK: Inputs

    public mutating func triggerDown(at t: TimeInterval) -> Action {
        switch state {
        case .idle:
            state = .firstDown(at: t)
        case .firstTapped(let up):
            if t - up <= window {
                state = .secondDown(at: t)
                return .startRecording
            }
            state = .firstDown(at: t)
        case .awaitingThird(let up):
            if t - up <= window {
                state = .lockPressed
                return .lock
            }
            // Too late for a triple: the timeout should already have discarded.
            state = .firstDown(at: t)
            return .discard
        case .locked:
            state = .lockedDown(at: t)
        case .firstDown, .secondDown, .lockPressed, .lockedDown, .lockedChord:
            break // a repeat "down" without an "up" — ignore
        }
        return .none
    }

    public mutating func triggerUp(at t: TimeInterval) -> Action {
        switch state {
        case .firstDown(let down):
            state = (t - down <= tapMax) ? .firstTapped(at: t) : .idle
        case .secondDown(let down):
            if t - down >= tapMax {
                state = .idle
                return .finish
            }
            state = .awaitingThird(at: t)
        case .lockPressed:
            state = .locked
        case .lockedDown(let down):
            if t - down <= tapMax {
                state = .idle
                return .finish
            }
            state = .locked // a long press while locked does nothing
        case .lockedChord:
            state = .locked
        case .idle, .firstTapped, .awaitingThird, .locked:
            break
        }
        return .none
    }

    /// Any non-trigger key, or another modifier joining the trigger.
    public mutating func otherKey(at t: TimeInterval) -> Action {
        switch state {
        case .firstDown, .firstTapped:
            state = .idle
        case .awaitingThird:
            state = .idle
            return .discard
        case .lockedDown:
            state = .lockedChord
        case .idle, .secondDown, .lockPressed, .locked, .lockedChord:
            break // typing while recording doesn't stop it
        }
        return .none
    }

    /// Call when `deadline` passes.
    public mutating func tick(at t: TimeInterval) -> Action {
        switch state {
        case .firstTapped(let up) where t - up >= window:
            state = .idle
        case .awaitingThird(let up) where t - up >= window:
            state = .idle
            return .discard
        default:
            break
        }
        return .none
    }

    // MARK: Host overrides

    /// The recording ended some other way (Esc, the HUD buttons, an error).
    public mutating func reset() { state = .idle }

    /// Lock from outside the gesture (the HUD's lock button), even mid-hold.
    public mutating func forceLock(triggerHeld: Bool) {
        state = triggerHeld ? .lockPressed : .locked
    }
}
