import AppKit
import ProsioCore

/// Global push-to-talk / toggle key via CGEventTap. Owned by mac-system agent.
///
/// NOTE for onboarding copy (mac-ui): users should set System Settings > Keyboard >
/// "Press \u{1F310} key to" = "Do Nothing" so the fn key doesn't also pop the emoji picker.
final class HotkeyMonitor {
    private let settings: AppSettings
    private let controller: DictationController

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine = HotkeyStateMachine()
    private var triggerPhysicallyDown = false
    /// True when the trigger went down together with an unrelated modifier (a real shortcut,
    /// e.g. Cmd+fn) so we know to ignore the matching key-up too.
    private var ignoringCurrentPress = false
    private var activationObserver: NSObjectProtocol?
    private var isStarted = false

    /// Every modifier bit we care about when deciding "no other modifiers held".
    private static let relevantModifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    init(settings: AppSettings, controller: DictationController) {
        self.settings = settings
        self.controller = controller
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installTap()
        // Input Monitoring permission may be granted after launch (from onboarding); retry
        // installing the tap whenever the app comes back to the foreground, same trigger the
        // PermissionsManager uses to refresh its own statuses.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread/MainActor's executor.
            MainActor.assumeIsolated {
                self?.installTap()
            }
        }
    }

    func stop() {
        isStarted = false
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        removeTap()
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Most likely missing Input Monitoring permission; PermissionsManager (or app
            // activation, above) will trigger a retry.
            eventTap = nil
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        stateMachine.reset()
        triggerPhysicallyDown = false
        ignoringCurrentPress = false
    }

    private func removeTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        stateMachine.reset()
        triggerPhysicallyDown = false
        ignoringCurrentPress = false
    }

    fileprivate func reenableTapAfterDisable() {
        // The system disables the tap after a timeout or suspicious user input; re-enabling is
        // the documented recovery. If that keeps failing we tear down and let the activation
        // observer (or a future PermissionsManager refresh) reinstall it from scratch.
        guard let tap = eventTap else {
            installTap()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        stateMachine.reset()
        triggerPhysicallyDown = false
        ignoringCurrentPress = false
    }

    // MARK: - Event handling (main actor)

    fileprivate func process(type: CGEventType, keycode: Int64, flagsRaw: UInt64, timestampNanos: UInt64) {
        let time = TimeInterval(timestampNanos) / 1_000_000_000
        let flags = CGEventFlags(rawValue: flagsRaw)
        switch type {
        case .flagsChanged:
            handleFlagsChanged(keycode: keycode, flags: flags, time: time)
        case .keyDown:
            handleKeyDown(keycode: keycode, time: time)
        default:
            break
        }
    }

    private func handleFlagsChanged(keycode: Int64, flags: CGEventFlags, time: TimeInterval) {
        let trigger = settings.triggerKey
        guard keycode == Self.keycode(for: trigger) else {
            // A different modifier changed while the trigger is held: treat like any other key.
            if triggerPhysicallyDown {
                applyEffect(stateMachine.otherKeyDown())
            }
            return
        }

        let triggerMask = Self.mask(for: trigger)
        let isDown = flags.contains(triggerMask)

        if isDown, !triggerPhysicallyDown {
            triggerPhysicallyDown = true
            let otherModifiers = flags.subtracting(triggerMask).intersection(Self.relevantModifierMask)
            if otherModifiers.isEmpty {
                applyEffect(stateMachine.triggerKeyDown(at: time, isBusy: controller.isBusy))
                ignoringCurrentPress = false
            } else {
                // A real shortcut combo (e.g. Cmd+fn): don't start, and ignore the matching key-up.
                ignoringCurrentPress = true
            }
        } else if !isDown, triggerPhysicallyDown {
            triggerPhysicallyDown = false
            if ignoringCurrentPress {
                ignoringCurrentPress = false
            } else {
                applyEffect(stateMachine.triggerKeyUp(at: time, holdThreshold: settings.holdThreshold))
            }
        }
    }

    private func handleKeyDown(keycode: Int64, time: TimeInterval) {
        if keycode == Self.escKeycode {
            applyEffect(stateMachine.escKeyDown(isBusy: controller.isBusy))
            return
        }
        if triggerPhysicallyDown {
            applyEffect(stateMachine.otherKeyDown())
        }
    }

    private func applyEffect(_ effect: HotkeyStateMachine.Effect) {
        switch effect {
        case .start:
            controller.start(trigger: .hold)
        case .stop:
            controller.stop()
        case .cancel:
            controller.cancel()
        case .none:
            break
        }
    }

    // MARK: - Keycodes

    private static let escKeycode: Int64 = 53

    private static func keycode(for trigger: TriggerKey) -> Int64 {
        switch trigger {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    private static func mask(for trigger: TriggerKey) -> CGEventFlags {
        switch trigger {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }

    fileprivate func handleTapDisabled() {
        reenableTapAfterDisable()
    }
}

/// C callback for `CGEvent.tapCreate`. Kept free of Swift concurrency isolation (it may run on
/// whatever thread the tap's run loop source fires on — in practice the main run loop, since
/// that's where `installTap()` adds the source, but nothing guarantees that statically). It
/// extracts plain, `Sendable` data and dispatches to the main actor to drive `HotkeyMonitor`,
/// which owns the `@MainActor`-isolated `DictationController`.
private nonisolated func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        runOnMainActor {
            monitor.handleTapDisabled()
        }
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flagsRaw = event.flags.rawValue
    let timestampNanos = event.timestamp

    // Synchronous, same-thread dispatch when we're already on the main thread (the normal case:
    // the tap's run loop source lives on the main run loop) removes scheduling latency and keeps
    // key-down/key-up ordering exact, which matters for the hold-vs-tap timing decision.
    runOnMainActor {
        monitor.process(type: type, keycode: keycode, flagsRaw: flagsRaw, timestampNanos: timestampNanos)
    }

    // Listen-only tap: return value is ignored by the system, but we must return something.
    return Unmanaged.passUnretained(event)
}

/// Runs `body` on the main actor. If already on the main thread (the tap callback's normal case),
/// runs it synchronously in place via `MainActor.assumeIsolated` — safe here because the main
/// thread *is* the MainActor's executor, so this isn't actually assuming anything beyond what
/// `Thread.isMainThread` just confirmed. Otherwise (defensive fallback; shouldn't normally happen
/// since `installTap()` always adds the run loop source on the main run loop) hops via `Task`.
private nonisolated func runOnMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            body()
        }
    } else {
        Task { @MainActor in
            body()
        }
    }
}
