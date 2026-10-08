import Foundation
import MurmurCore

// Self-checks for the pure logic. Run with: swift run murmur-check

var failures = 0
@MainActor func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { print("  ok   \(name)") } else { print("  FAIL \(name)  (line \(line))"); failures += 1 }
}

/// Feeds a script of events to a fresh gesture and returns the non-`.none` actions.
@MainActor func run(_ steps: [(String, Double)]) -> (actions: [TapGesture.Action], gesture: TapGesture) {
    var g = TapGesture()
    var actions: [TapGesture.Action] = []
    for (kind, t) in steps {
        // Fire any timeout that would have passed before this event.
        if let d = g.deadline, d <= t { let a = g.tick(at: d); if a != .none { actions.append(a) } }
        let a: TapGesture.Action
        switch kind {
        case "d": a = g.triggerDown(at: t)
        case "u": a = g.triggerUp(at: t)
        case "k": a = g.otherKey(at: t)
        case "t": a = g.tick(at: t)
        default: fatalError(kind)
        }
        if a != .none { actions.append(a) }
    }
    return (actions, g)
}

print("Gesture")
do {
    let r = run([("d", 0), ("u", 0.1), ("d", 0.25), ("u", 2.0)])
    check(r.actions == [.startRecording, .finish], "double-tap and hold records, release inserts")
    check(r.gesture.state == .idle, "back to idle after push-to-talk")
}
do {
    let r = run([("d", 0), ("u", 0.1), ("d", 0.25), ("u", 0.33), ("d", 0.45), ("u", 0.55)])
    check(r.actions == [.startRecording, .lock], "triple-tap locks")
    check(r.gesture.isLocked && r.gesture.isRecording, "locked state is recording")
    var g = r.gesture
    check(g.triggerDown(at: 9.0) == .none, "tap while locked: press does nothing yet")
    check(g.triggerUp(at: 9.1) == .finish, "tap while locked: release finishes")
}
do {
    let r = run([("d", 0), ("u", 0.1), ("d", 0.25), ("u", 0.33), ("t", 1.0)])
    check(r.actions == [.startRecording, .discard], "quick double-tap with no third tap is discarded")
}
do {
    let r = run([("d", 0), ("k", 0.05), ("u", 0.1), ("d", 0.25), ("u", 2.0)])
    check(!r.actions.contains(.startRecording), "Shift+letter then Shift does not start recording")
}
do {
    let r = run([("d", 0), ("u", 0.1), ("k", 0.15), ("d", 0.25), ("u", 2.0)])
    check(!r.actions.contains(.startRecording), "tap, letter, tap does not start recording")
}
do {
    let r = run([("d", 0), ("u", 0.1), ("d", 0.9), ("u", 3.0)])
    check(r.actions.isEmpty, "taps too far apart do nothing")
}
do {
    let r = run([("d", 0), ("u", 0.6), ("d", 0.7), ("u", 2.0)])
    check(r.actions.isEmpty, "a long first press is not a tap")
}
do {
    let r = run([("d", 0), ("u", 0.1), ("d", 0.25), ("k", 0.5), ("u", 2.0)])
    check(r.actions == [.startRecording, .finish], "typing while holding keeps recording")
}
do {
    // Locked, then Shift+A typed: the chord must not finish the recording.
    var r = run([("d", 0), ("u", 0.1), ("d", 0.25), ("u", 0.33), ("d", 0.45), ("u", 0.55)])
    check(r.gesture.triggerDown(at: 5.0) == .none, "locked chord: press")
    check(r.gesture.otherKey(at: 5.05) == .none, "locked chord: letter")
    check(r.gesture.triggerUp(at: 5.1) == .none, "locked chord: release does not finish")
    check(r.gesture.isLocked, "still locked after a chord")
}
do {
    var r = run([("d", 0), ("u", 0.1), ("d", 0.25)])
    r.gesture.forceLock(triggerHeld: true)
    check(r.gesture.triggerUp(at: 3.0) == .none, "HUD lock mid-hold: release keeps recording")
    check(r.gesture.isLocked, "HUD lock mid-hold: locked")
}

print("Text")
check(Commands.isAbort("Scratch that."), "abort phrase")
check(!Commands.isAbort("scratch that idea about the logo"), "abort only as the whole utterance")
check(Commands.applyInline("Hi Jack, new line thanks for that.") == "Hi Jack,\nThanks for that.", "new line")
check(Commands.applyInline("One. New paragraph. Two.") == "One.\n\nTwo.", "new paragraph")
check(Replacements.apply(["acu panel": "Acupanel"], to: "The acu panel range.") == "The Acupanel range.", "replacement")
check(Replacements.apply(["wvh": "WVH"], to: "wvhx and wvh.") == "wvhx and WVH.", "replacement is whole-word")
check(Spacing.join(previous: "d", text: "Next") == " Next", "space after a word")
check(Spacing.join(previous: " ", text: "Next") == "Next", "no space after a space")
check(Spacing.join(previous: "d", text: ", then") == ", then", "no space before punctuation")
check(Spacing.join(previous: nil, text: "Next") == "Next", "unknown context adds nothing")
check(NonSpeech.strip("[BLANK_AUDIO] Hello (upbeat music) there") == "Hello there", "strip non-speech")
check(Hallucination.isLikely("Thank you.", voicedSeconds: 0.1), "silent 'Thank you.' is dropped")
check(!Hallucination.isLikely("Thank you.", voicedSeconds: 0.7), "spoken 'Thank you.' is kept")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
