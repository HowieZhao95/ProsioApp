import AppKit
import Carbon.HIToolbox
import Observation
import ProsioCore

/// Global toggle hotkey via CGEventTap: press once to start (dictate/edit/ask/translate are all
/// resolved by core from the transcript — see `DictationIntent`/spoken keyword prefixes), press
/// again to stop. Owned by mac-system agent.
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
    private var inputMonitoringGrantedAtTapInstall = false
    /// Tracks physical down/up purely to filter out auto-repeat/duplicate-down observations and
    /// to ignore key-up entirely — see `TriggerPhysicalState`'s doc comment. `HotkeyStateMachine`
    /// itself has no persistent state (every decision reads `controller.phase` fresh), so there's
    /// nothing else to keep in sync here.
    private var triggerPhysicalState = TriggerPhysicalState()
    private var captureOptionState = CaptureOptionTapState()
    @ObservationIgnored var isOptionCaptureSelected: () -> Bool = { false }
    @ObservationIgnored var isOptionCaptureBusy: () -> Bool = { true }
    @ObservationIgnored var onOptionCaptureTap: () -> Void = {}
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var watchdogTimer: Timer?
    /// Fallback Esc handling: on this machine's config (Input Monitoring denied, Accessibility
    /// granted), `keyDown`/`keyUp` events are silently dropped by the `CGEventTap` even though
    /// it's alive and `flagsChanged` events (the trigger key) come through fine — macOS gates
    /// keyDown/keyUp delivery through event taps on Input Monitoring specifically, tap mode
    /// (`.defaultTap` vs `.listenOnly`) doesn't matter. `NSEvent` global keyDown monitors turned
    /// out to be gated by Input Monitoring too (confirmed live), so Esc instead uses a Carbon
    /// global hotkey (`RegisterEventHotKey`) for `kVK_Escape` with no modifiers — hotkeys are a
    /// distinct, older mechanism that needs no TCC permission at all. Registered only while
    /// `HotkeyStateMachine.needsEscMonitor` says there's something Esc could do; while registered
    /// it consumes Esc system-wide (the front app never sees it), which is the deliberate,
    /// accepted trade-off for those windows (listening/answering).
    @ObservationIgnored private var escHotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var escHotKeyEventHandlerRef: EventHandlerRef?
    /// Kept as a belt-and-suspenders backstop alongside the hotkey (e.g. in case a focused Prosio
    /// text field ever intercepts Escape before the hotkey manager sees it) — local-only, so it
    /// needs no permission and only ever sees events sent to our own app.
    @ObservationIgnored private var escLocalMonitor: Any?
    private var isStarted = false
    var isCaptureSuspended = false {
        didSet { triggerPhysicalState.reset(); captureOptionState.reset(); updateEscMonitors() }
    }
    var isMeetingSuspended = false {
        didSet { triggerPhysicalState.reset() }
    }
    var isRecordingSuspended = false {
        didSet { triggerPhysicalState.reset(); captureOptionState.reset() }
    }
    func resetCaptureOptionGesture() { captureOptionState.reset() }

    /// Every modifier bit we care about when deciding "no other modifiers held" (so a real
    /// shortcut combo like Cmd+fn isn't mistaken for a trigger press).
    private static let relevantModifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
    /// How often the watchdog checks the tap's health.
    private static let watchdogInterval: TimeInterval = 2.0
    /// Arbitrary 4-char signature identifying our hotkey registration; only meaningful to us.
    private static let escHotKeySignature: FourCharCode = fourCharCode("PrsE")
    private static let escHotKeyID = EventHotKeyID(signature: escHotKeySignature, id: 1)

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(byte)
        }
        return result
    }

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
                self?.refreshTapForInputMonitoring()
            }
        }

        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer

        updateEscMonitors() // in case we're somehow starting mid-session
        observePhaseForEscMonitor()
    }

    func stop() {
        isStarted = false
        captureOptionState.reset()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        unregisterEscHotKey()
        removeTap()
    }

    // MARK: - Esc fallback (Carbon hotkey; see `escHotKeyRef`'s doc comment)

    /// Re-registers itself after every `controller.phase` change (`withObservationTracking`'s
    /// `onChange` fires once per registration) so the Esc hotkey stays in sync with phase for as
    /// long as `isStarted`.
    private func observePhaseForEscMonitor() {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            // `onChange` can fire on an arbitrary execution context; hop back to the main actor
            // before touching `controller`/`self` again.
            DispatchQueue.main.async {
                guard let self, self.isStarted else { return }
                self.updateEscMonitors()
                self.observePhaseForEscMonitor()
            }
        }
    }

    private func updateEscMonitors() {
        if !isCaptureSuspended && HotkeyStateMachine.needsEscMonitor(phase: controller.phase) {
            registerEscHotKeyIfNeeded()
        } else {
            unregisterEscHotKey()
        }
    }

    private func registerEscHotKeyIfNeeded() {
        guard escHotKeyRef == nil else { return }
        installEscHotKeyEventHandlerIfNeeded()

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0, // no modifiers
            Self.escHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            ProsioLog.hotkey.error("RegisterEventHotKey(Escape) failed: status=\(status, privacy: .public)")
            return
        }
        escHotKeyRef = hotKeyRef

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEscCandidateEvent(event)
            return event
        }
        ProsioLog.hotkey.info("esc hotkey registered")
    }

    private func installEscHotKeyEventHandlerIfNeeded() {
        guard escHotKeyEventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), escHotKeyEventHandler, 1, &eventType, selfPtr, &handlerRef)
        if status == noErr {
            escHotKeyEventHandlerRef = handlerRef
        } else {
            ProsioLog.hotkey.error("InstallEventHandler(Esc hotkey) failed: status=\(status, privacy: .public)")
        }
    }

    private func unregisterEscHotKey() {
        let wasRegistered = escHotKeyRef != nil || escLocalMonitor != nil
        if let escHotKeyRef {
            UnregisterEventHotKey(escHotKeyRef)
        }
        if let escLocalMonitor {
            NSEvent.removeMonitor(escLocalMonitor)
        }
        escHotKeyRef = nil
        escLocalMonitor = nil
        if wasRegistered {
            ProsioLog.hotkey.info("esc hotkey unregistered")
        }
        // The event handler itself is deliberately left installed (InstallEventHandler'd once,
        // lazily, the first time it's needed): it's harmless with no hotkey registered — it just
        // won't receive kEventHotKeyPressed — and re-installing it every cycle isn't worth it.
    }

    /// Called (via `escHotKeyEventHandler`, dispatched to the main actor) whenever our Escape
    /// hotkey fires. We only ever register one hotkey, so any invocation is unambiguously ours —
    /// no need to read back and check the `EventHotKeyID`.
    fileprivate func handleEscHotKeyPressed() {
        guard !isCaptureSuspended else { return }
        let phase = controller.phase
        let effect = HotkeyStateMachine.escKeyDown(phase: phase)
        if effect != .none {
            ProsioLog.hotkey.info("esc (hotkey) while phase=\(String(describing: phase), privacy: .public) -> effect=\(String(describing: effect), privacy: .public)")
        }
        scheduleEffect(effect)
    }

    /// Backstop path via the local `NSEvent` monitor (own-app-only, no permission needed) —
    /// see `escLocalMonitor`'s doc comment.
    private func handleEscCandidateEvent(_ event: NSEvent) {
        guard event.keyCode == UInt16(Self.escKeycode) else { return }
        let phase = controller.phase
        let effect = HotkeyStateMachine.escKeyDown(phase: phase)
        if effect != .none {
            ProsioLog.hotkey.info("esc (local NSEvent) while phase=\(String(describing: phase), privacy: .public) -> effect=\(String(describing: effect), privacy: .public)")
        }
        scheduleEffect(effect)
    }

    // MARK: - Watchdog

    /// Runs every `watchdogInterval` while started. Covers the cases the event-driven paths can
    /// miss: Accessibility granted without the app coming back to the foreground, and the tap
    /// getting silently disabled without a `tapDisabledBy*` callback reaching us. (There's no
    /// hotkey-state staleness to check anymore — `HotkeyStateMachine` has no persistent state.)
    private func watchdogTick() {
        refreshTapForInputMonitoring()
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

    private func refreshTapForInputMonitoring() {
        if eventTap != nil, CGPreflightListenEventAccess() != inputMonitoringGrantedAtTapInstall {
            removeTap()
        }
        if eventTap == nil, AXIsProcessTrusted() { installTap() }
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        guard eventTap == nil else { return }
        let observedTypes: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ]
        let mask = observedTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
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
        inputMonitoringGrantedAtTapInstall = CGPreflightListenEventAccess()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapHealthy = true
        triggerPhysicalState.reset()
        captureOptionState.reset()
        ProsioLog.hotkey.info("tap installed")
        ProsioLog.hotkey.notice("option diagnostic tap installed ax=\(AXIsProcessTrusted(), privacy: .public) im=\(CGPreflightListenEventAccess(), privacy: .public) healthy=\(self.isTapHealthy, privacy: .public)")
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
        captureOptionState.reset()
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
        captureOptionState.reset()
        ProsioLog.hotkey.info("tap re-enable result: healthy=\(self.isTapHealthy, privacy: .public), accessibilityGranted=\(accessibilityGranted, privacy: .public)")
    }

    // MARK: - Event handling (main actor)

    /// Decides what effect (if any) an event produces, purely via the state machine — cheap and
    /// non-blocking. Does NOT call into `DictationController` itself; see `scheduleEffect`.
    fileprivate func decideEffect(type: CGEventType, keycode: Int64, flagsRaw: UInt64, timestamp: TimeInterval) {
        if type == .flagsChanged, keycode == 58 || keycode == 61 {
            ProsioLog.hotkey.notice("option flag event keycode=\(keycode, privacy: .public) deviceBits=\(flagsRaw & 0xff, privacy: .public) suspended=\(self.isCaptureSuspended, privacy: .public)")
        }
        guard !isCaptureSuspended else { return }
        let flags = CGEventFlags(rawValue: flagsRaw)
        switch type {
        case .flagsChanged:
            handleOptionFlagsChanged(keycode: keycode, flagsRaw: flagsRaw, flags: flags, timestamp: timestamp)
            handleFlagsChanged(keycode: keycode, flags: flags)
        case .keyDown:
            if captureOptionState.isPending { ProsioLog.hotkey.notice("option gesture interrupted by key event") }
            _ = captureOptionState.observe(event: .interruption, at: timestamp, eligible: false)
            handleKeyDown(keycode: keycode)
        case .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
            if captureOptionState.isPending {
                ProsioLog.hotkey.notice("option gesture interrupted by input event type=\(type.rawValue, privacy: .public)")
            }
            _ = captureOptionState.observe(event: .interruption, at: timestamp, eligible: false)
        default:
            break
        }
    }

    private func handleOptionFlagsChanged(keycode: Int64, flagsRaw: UInt64, flags: CGEventFlags, timestamp: TimeInterval) {
        let event = HotkeyRouting.optionFlagEvent(keycode: keycode, flagsRaw: flagsRaw)
        guard keycode == 58 || keycode == 61 else {
            if captureOptionState.isPending {
                ProsioLog.hotkey.notice("option gesture interrupted by modifier keycode=\(keycode, privacy: .public)")
            }
            _ = captureOptionState.observe(event: event, at: timestamp, eligible: false)
            return
        }
        let otherModifiers = flags.intersection([.maskShift, .maskControl, .maskCommand, .maskSecondaryFn])
        // At either side's transition the current event's device bits identify whether the
        // opposite Option is held. CGEventSource.keyState misreports Option during release.
        let oppositeOptionDown = HotkeyRouting.oppositeOptionIsDown(keycode: keycode, flagsRaw: flagsRaw)
        let physical = Self.physicalBlockers()
        let selected = isOptionCaptureSelected()
        let busy = isOptionCaptureBusy()
        let ax = AXIsProcessTrusted()
        let im = CGPreflightListenEventAccess()
        let availability = HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: settings.triggerKey == .rightOption,
            accessibilityGranted: ax, inputMonitoringGranted: im, tapHealthy: isTapHealthy)
        let eligible = isStarted && !isCaptureSuspended && selected && !busy && availability == .ready
            && otherModifiers.isEmpty
            && !oppositeOptionDown
            && !physical.hasAny
        let elapsedMS = Int(((captureOptionState.elapsed(at: timestamp) ?? -1) * 1000).rounded())
        let fired = captureOptionState.observe(event: event, at: timestamp, eligible: eligible)
        ProsioLog.hotkey.notice("option decision keycode=\(keycode, privacy: .public) event=\(String(describing: event), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) started=\(self.isStarted, privacy: .public) suspended=\(self.isCaptureSuspended, privacy: .public) selected=\(selected, privacy: .public) busy=\(busy, privacy: .public) phase=\(self.voicePhaseName, privacy: .public) ax=\(ax, privacy: .public) im=\(im, privacy: .public) tapHealthy=\(self.isTapHealthy, privacy: .public) availability=\(String(describing: availability), privacy: .public) otherModifiers=\(!otherModifiers.isEmpty, privacy: .public) oppositeOption=\(oppositeOptionDown, privacy: .public) keyBlock=\(physical.keycode, privacy: .public) mouseBlock=\(physical.mouseRaw, privacy: .public) eligible=\(eligible, privacy: .public) fire=\(fired, privacy: .public)")
        guard fired else { return }
        // The callback may be queued behind a settings/voice/capture change; gate again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allowed = self.optionCaptureEligible()
            ProsioLog.hotkey.notice("option queued dispatch allowed=\(allowed, privacy: .public) selected=\(self.isOptionCaptureSelected(), privacy: .public) busy=\(self.isOptionCaptureBusy(), privacy: .public)")
            guard allowed else { return }
            self.onOptionCaptureTap()
        }
    }

    private var voicePhaseName: String {
        switch controller.phase {
        case .idle: "idle"
        case .listening: "listening"
        case .finalizing: "finalizing"
        case .composing: "composing"
        case .inserting: "inserting"
        case .answering: "answering"
        case .finished: "finished"
        case .failed: "failed"
        }
    }

    private func optionCaptureEligible() -> Bool {
        guard isStarted, !isCaptureSuspended, isOptionCaptureSelected(), !isOptionCaptureBusy() else { return false }
        return HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: settings.triggerKey == .rightOption,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            tapHealthy: isTapHealthy
        ) == .ready
    }

    /// Physical-state backstop for an already-held key/button before Option went down.
    /// The event tap also invalidates a tap on every key or mouse transition while held.
    private struct PhysicalBlockers {
        var keycode = -1
        var mouseRaw = -1
        var hasAny: Bool { keycode >= 0 || mouseRaw >= 0 }
    }

    private static func physicalBlockers() -> PhysicalBlockers {
        var result = PhysicalBlockers()
        let modifierKeys: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        for key in CGKeyCode(0)...CGKeyCode(127) where !modifierKeys.contains(key) {
            if CGEventSource.keyState(.combinedSessionState, key: key) {
                result.keycode = Int(key)
                break
            }
        }
        for raw in 0..<32 {
            guard let button = CGMouseButton(rawValue: UInt32(raw)) else { continue }
            if CGEventSource.buttonState(.combinedSessionState, button: button) {
                result.mouseRaw = raw
                break
            }
        }
        return result
    }

    private func handleFlagsChanged(keycode: Int64, flags: CGEventFlags) {
        guard !isMeetingSuspended, !isRecordingSuspended else { return }
        let key = settings.triggerKey
        guard keycode == Self.keycode(for: key) else { return }

        let mask = Self.mask(for: key)
        let isDown = flags.contains(mask)
        let isRepeat = triggerPhysicalState.observe(isDown: isDown)

        // Key-up is ignored entirely (toggle is driven by down only), and so is a repeated
        // observation of the same state (auto-repeat/duplicate, or a redundant up).
        guard isDown, !isRepeat else { return }

        let otherModifiers = flags.subtracting(mask).intersection(Self.relevantModifierMask)
        guard otherModifiers.isEmpty else {
            // A real shortcut combo (e.g. Cmd+fn), not a trigger press.
            return
        }

        let phase = controller.phase
        let effect = HotkeyStateMachine.triggerKeyDown(phase: phase)
        ProsioLog.hotkey.info("trigger down, phase=\(String(describing: phase), privacy: .public) -> effect=\(String(describing: effect), privacy: .public)")
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
        guard !isMeetingSuspended, !isRecordingSuspended else { return }
        guard HotkeyRouting.canApplyVoiceEffect(isStarted: isStarted, isCaptureSuspended: isCaptureSuspended) else { return }
        switch effect {
        case .start:
            // Intent is always nil now: core auto-resolves dictate/edit from selection, and
            // Ask/Translate are spoken keyword prefixes rather than a separate hotkey/intent.
            controller.start(trigger: .toggle, intent: nil)
        case .dismissAnswer:
            controller.dismissAnswer()
        case .stop:
            controller.stop()
        case .cancel:
            controller.cancel()
        case .ignore, .none:
            break
        }
    }

    private func scheduleEffect(_ effect: HotkeyStateMachine.Effect) {
        switch effect {
        case .ignore, .none:
            return
        case .start, .dismissAnswer, .stop, .cancel:
            break
        }
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
    let timestamp = TimeInterval(event.timestamp) / 1_000_000_000

    // Synchronous, same-thread dispatch when we're already on the main thread (the normal case:
    // the tap's run loop source lives on the main run loop) removes scheduling latency. This only
    // decides the effect (pure state-machine logic reading `controller.phase`); it never blocks
    // — see `decideEffect`.
    runOnMainActor {
        monitor.decideEffect(type: type, keycode: keycode, flagsRaw: flagsRaw, timestamp: timestamp)
    }

    // Active tap: returning the event unmodified passes it through unchanged.
    return Unmanaged.passUnretained(event)
}

/// C callback for `InstallEventHandler`, handling `kEventClassKeyboard`/`kEventHotKeyPressed` for
/// our registered Escape hotkey. Kept free of Swift concurrency isolation for the same reason as
/// `hotkeyEventTapCallback` above; dispatches to the main actor before touching `HotkeyMonitor`.
private nonisolated func escHotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    eventRef: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    guard GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID) == noErr,
          HotkeyRouting.isVoiceEscape(signature: hotkeyID.signature, id: hotkeyID.id) else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    runOnMainActor {
        monitor.handleEscHotKeyPressed()
    }
    return noErr
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
