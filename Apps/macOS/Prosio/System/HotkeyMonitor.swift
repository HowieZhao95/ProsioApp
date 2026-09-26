import AppKit
import Observation
import ProsioCore

/// Global toggle hotkey via CGEventTap: press once to start, press again to stop. Owned by
/// mac-system agent.
///
/// NOTE for onboarding copy (mac-ui): users should set System Settings > Keyboard >
/// "Press \u{1F310} key to" = "Do Nothing" so the fn key doesn't also pop the emoji picker.
@Observable
final class HotkeyMonitor {
    /// True when the tap exists and is currently enabled. Read by `AppEnvironment.hotkeyStatus`
    /// to surface a "tap disabled" status to the UI.
    private(set) var isTapHealthy = false

    private let settings: AppSettings
    private let controller: DictationController

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Tracks physical down/up purely to filter out auto-repeat/duplicate-down observations and
    /// to ignore key-up entirely — see its doc comment. `HotkeyStateMachine` itself has no
    /// persistent state (every decision reads `controller.phase` fresh), so there's nothing else
    /// to keep in sync here.
    private var triggerPhysicalState = TriggerPhysicalState()
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var watchdogTimer: Timer?
    private var isStarted = false

    /// Every modifier bit we care about when deciding "no other modifiers held" (so a real
    /// shortcut combo like Cmd+fn isn't mistaken for a trigger press).
    private static let relevantModifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
    /// How often the watchdog checks the tap's health.
    private static let watchdogInterval: TimeInterval = 2.0

    init(settings: AppSettings, controller: DictationController) {
        self.settings = settings
        self.controller = controller
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installTap()

        // Accessibility permission may be granted after launch (from onboarding); retry
        // installing the tap whenever the app comes back to the foreground, same trigger the
        // PermissionsManager uses to refresh its own statuses. This covers the common case
        // quickly; the watchdog timer below is the fallback for when activation doesn't fire.
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

        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    func stop() {
        isStarted = false
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        removeTap()
    }

    // MARK: - Watchdog

    /// Runs every `watchdogInterval` while started. Covers the cases the event-driven paths can
    /// miss: Accessibility granted without the app coming back to the foreground, and the tap
    /// getting silently disabled without a `tapDisabledBy*` callback reaching us. (There's no
    /// hotkey-state staleness to check anymore — `HotkeyStateMachine` has no persistent state.)
    private func watchdogTick() {
        if eventTap == nil {
            if AXIsProcessTrusted() {
                ProsioLog.hotkey.info("watchdog: Accessibility now granted, installing tap")
                installTap()
            }
        } else if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            ProsioLog.hotkey.info("watchdog: tap found disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            isTapHealthy = CGEvent.tapIsEnabled(tap: tap)
        } else {
            isTapHealthy = true
        }
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active (default) tap that passes every event through unchanged: unlike a listen-only
            // tap it needs only Accessibility, not Input Monitoring (one permission fewer).
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Most likely missing Accessibility permission; the watchdog (or app activation,
            // above) will retry.
            eventTap = nil
            isTapHealthy = false
            ProsioLog.hotkey.error("tap create failed (likely missing Accessibility)")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapHealthy = true
        triggerPhysicalState.reset()
        ProsioLog.hotkey.info("tap installed")
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
        isTapHealthy = false
        triggerPhysicalState.reset()
    }

    fileprivate func handleTapDisabled(reason: String) {
        isTapHealthy = false
        // `CGEvent.tapIsEnabled` can read misleadingly while Accessibility is actually denied
        // (the tap can appear to toggle even though the OS won't really deliver events); log the
        // permission alongside so a stuck "healthy=false" loop is easy to tell apart from that.
        let accessibilityGranted = AXIsProcessTrusted()
        ProsioLog.hotkey.info("tap disabled by system (\(reason, privacy: .public)); re-enabling, accessibilityGranted=\(accessibilityGranted, privacy: .public)")
        // The system disables the tap after a timeout or suspicious user input; re-enabling is
        // the documented recovery. If the tap itself is gone, fall back to a full reinstall.
        guard let tap = eventTap else {
            installTap()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapHealthy = CGEvent.tapIsEnabled(tap: tap)
        triggerPhysicalState.reset()
        ProsioLog.hotkey.info("tap re-enable result: healthy=\(self.isTapHealthy, privacy: .public), accessibilityGranted=\(accessibilityGranted, privacy: .public)")
    }

    // MARK: - Event handling (main actor)

    /// Decides what effect (if any) an event produces, purely via the state machine — cheap and
    /// non-blocking. Does NOT call into `DictationController` itself; see `scheduleEffect`.
    fileprivate func decideEffect(type: CGEventType, keycode: Int64, flagsRaw: UInt64) {
        let flags = CGEventFlags(rawValue: flagsRaw)
        switch type {
        case .flagsChanged:
            handleFlagsChanged(keycode: keycode, flags: flags)
        case .keyDown:
            handleKeyDown(keycode: keycode)
        default:
            break
        }
    }

    private func handleFlagsChanged(keycode: Int64, flags: CGEventFlags) {
        let trigger = settings.triggerKey
        guard keycode == Self.keycode(for: trigger) else { return }

        let triggerMask = Self.mask(for: trigger)
        let isDown = flags.contains(triggerMask)
        let isRepeat = triggerPhysicalState.observe(isDown: isDown)

        // Key-up is ignored entirely (toggle is driven by down only), and so is a repeated
        // observation of the same state (auto-repeat/duplicate, or a redundant up).
        guard isDown, !isRepeat else { return }

        let otherModifiers = flags.subtracting(triggerMask).intersection(Self.relevantModifierMask)
        guard otherModifiers.isEmpty else {
            // A real shortcut combo (e.g. Cmd+fn), not a trigger press.
            return
        }

        let phase = controller.phase
        let effect = HotkeyStateMachine.triggerKeyDown(phase: phase)
        if effect == .ignore {
            ProsioLog.hotkey.info("trigger down while phase=\(String(describing: phase), privacy: .public) -> ignored (previous session still finishing)")
        } else {
            ProsioLog.hotkey.info("trigger down while phase=\(String(describing: phase), privacy: .public) -> effect=\(String(describing: effect), privacy: .public)")
        }
        scheduleEffect(effect)
    }

    private func handleKeyDown(keycode: Int64) {
        guard keycode == Self.escKeycode else { return }
        let phase = controller.phase
        let effect = HotkeyStateMachine.escKeyDown(phase: phase)
        if effect != .none {
            ProsioLog.hotkey.info("esc while phase=\(String(describing: phase), privacy: .public) -> effect=\(String(describing: effect), privacy: .public)")
        }
        scheduleEffect(effect)
    }

    /// Applies `effect` to `DictationController`. From the tap callback's `decideEffect` path,
    /// this is always reached via `scheduleEffect`'s `DispatchQueue.main.async` (never called
    /// synchronously from inside the callback): `controller.start()` can do blocking work (opening
    /// the microphone, synchronous Accessibility IPC for focus context), and running that inline in
    /// the CGEventTap callback's call frame — even though it's already on the main thread — risks
    /// the system flagging the tap as unresponsive and disabling it.
    private func applyEffect(_ effect: HotkeyStateMachine.Effect) {
        switch effect {
        case .start:
            controller.start(trigger: .toggle)
        case .stop:
            controller.stop()
        case .cancel:
            controller.cancel()
        case .ignore, .none:
            break
        }
    }

    private func scheduleEffect(_ effect: HotkeyStateMachine.Effect) {
        guard effect == .start || effect == .stop || effect == .cancel else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyEffect(effect)
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
}

/// C callback for `CGEvent.tapCreate`. Kept free of Swift concurrency isolation (it may run on
/// whatever thread the tap's run loop source fires on — in practice the main run loop, since
/// that's where `installTap()` adds the source, but nothing guarantees that statically). It
/// extracts plain, `Sendable` data and dispatches to the main actor to decide the effect (cheap,
/// non-blocking); the actual `DictationController` call is queued separately — see
/// `HotkeyMonitor.applyEffect`'s doc comment — so this callback returns as quickly as possible.
private nonisolated func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        runOnMainActor {
            monitor.handleTapDisabled(reason: reason)
        }
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flagsRaw = event.flags.rawValue

    // Synchronous, same-thread dispatch when we're already on the main thread (the normal case:
    // the tap's run loop source lives on the main run loop) removes scheduling latency. This only
    // decides the effect (pure state-machine logic reading `controller.phase`); it never blocks
    // — see `decideEffect`.
    runOnMainActor {
        monitor.decideEffect(type: type, keycode: keycode, flagsRaw: flagsRaw)
    }

    // Active tap: returning the event unmodified passes it through unchanged.
    return Unmanaged.passUnretained(event)
}

/// Runs `body` on the main actor. If already on the main thread (the tap callback's normal case),
/// runs it synchronously in place via `MainActor.assumeIsolated` — safe here because the main
/// thread *is* the MainActor's executor, so this isn't actually assuming anything beyond what
/// `Thread.isMainThread` just confirmed. Otherwise (defensive fallback; shouldn't normally happen
/// since `installTap()` always adds the run loop source on the main run loop) hops via `Task`.
/// `body` itself must stay cheap and non-blocking — see the callers.
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
