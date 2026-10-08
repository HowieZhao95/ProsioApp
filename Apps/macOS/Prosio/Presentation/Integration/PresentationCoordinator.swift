import AppKit
import Observation

@Observable @MainActor
final class PresentationCoordinator {
    let preferences: PresentationPreferences
    let awake: AwakeService
    private(set) var state = PresentationState()
    private(set) var keysStatus = "关闭"
    var excludedBundleIDs: String {
        didSet { defaults.set(excludedBundleIDs, forKey: "prosio.presentation.excludedApps"); clearChord() }
    }
    /// Assigned at the composition root to keep existing Prosio control shortcuts private.
    @ObservationIgnored var isControlShortcut: (Int64, CGEventFlags) -> Bool = { _, _ in false }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let input = PresentationInputMonitor()
    @ObservationIgnored private let overlays: PresentationOverlays
    @ObservationIgnored private var chord = PresentationChord()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var environmentSuspended = false
    private var locked = false
    private var lastRetry: TimeInterval = 0
    private(set) var revision = 0
    @ObservationIgnored private var keyboardEvents = 0
    @ObservationIgnored private var displayedChords = 0
    @ObservationIgnored private var previewDeadline: TimeInterval?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = PresentationPreferences(defaults: defaults)
        awake = AwakeService()
        overlays = PresentationOverlays(preferences: preferences)
        excludedBundleIDs = defaults.string(forKey: "prosio.presentation.excludedApps") ?? ""
        input.onEvent = { [weak self] type, event in self?.receive(type, event: event) }
        input.onInterruption = { [weak self] in self?.clearChord() }
    }
    var pointerEnabled: Bool { state.pointerRequested }
    var keysEnabled: Bool { state.keysRequested }
    var pointerStatus: String {
        if !state.pointerRequested { return "关闭" }
        return canShowVisuals ? "运行中" : "已暂停"
    }
    private var canShowVisuals: Bool { state.visualsAllowed && !environmentSuspended && !locked }
    private var excludedApp: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        let exclusions = excludedBundleIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return id == Bundle.main.bundleIdentifier || exclusions.contains(id)
    }

    func launch() {
        guard timer == nil else { return }
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { $0.suspendForLock() }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: NSWorkspace.shared.notificationCenter) { $0.suspendForLock() }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { $0.unlock() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: NSWorkspace.shared.notificationCenter) { $0.unlock() }
        observe(Notification.Name("com.apple.screenIsLocked"), center: DistributedNotificationCenter.default()) { $0.suspendForLock() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: DistributedNotificationCenter.default()) { $0.unlock() }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) {
            $0.overlays.clear(); $0.clearChord(); $0.refresh()
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh()
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        input.stop(); overlays.clear(); chord.clear(); awake.stopAll()
        previewDeadline = nil
        state = PresentationState(); setKeysStatus("关闭")
    }
    func begin() {
        guard state.phase == .idle else { return }
        state.begin(pointer: preferences.sessionPointer, keys: preferences.sessionKeys)
        if preferences.sessionAwake && !locked { awake.start(.session, duration: nil) }
        refresh()
    }
    func end() { state.end(); awake.stop(.session); refresh() }
    func pause() { state.pause(); refresh() }
    func resume() { guard !locked else { return }; state.resume(); refresh() }
    func previewKeycap() {
        guard canShowVisuals, !input.secureInput else { return }
        let now = PresentationClock.now()
        previewDeadline = now + 3
        chord.press(label: "⌘ ⇧ S", keyCode: -1, at: now)
        chord.release(keyCode: -1, at: now, linger: 3)
        overlays.showChord(chord)
    }
    func privacyStop() { state.privacyStop(); refresh() }
    func setPointer(_ enabled: Bool) { state.manualPointer = enabled; refresh() }
    func setKeys(_ enabled: Bool) { state.manualKeys = enabled; refresh() }
    func setEnvironmentSuspended(_ suspended: Bool) { environmentSuspended = suspended; refresh() }
    func startManualAwake(minutes: Int?) {
        guard !locked else { return }
        awake.start(.manual, duration: minutes.map { Double($0) * 60 })
    }
    private func suspendForLock() {
        locked = true
        state.privacyStop()
        awake.stopAll()
        refresh()
    }
    private func unlock() { locked = false; refresh() } // explicit resume required after lock
    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping @MainActor (PresentationCoordinator) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, observer))
    }
    private func tick() {
        awake.tick()
        // Observable revision drives remaining-time text without persisting countdown ticks.
        let second = Int(PresentationClock.now())
        if revision != second {
            revision = second
            writeDiagnostics()
        }
        refresh()
        chord.expire(at: PresentationClock.now())
        if chord.label == nil { overlays.clearKeys() }
    }
    private func refresh() {
        overlays.setPointerEnabled(state.pointerActive && canShowVisuals)
        guard canShowVisuals else { input.stop(); clearChord(keepingPreview: false); setKeysStatus("已暂停"); return }
        guard !input.secureInput else { input.stop(); clearChord(keepingPreview: false); setKeysStatus("安全输入中 · 已暂停"); return }
        guard state.keysRequested else { input.stop(); clearChord(); setKeysStatus("关闭"); return }
        guard input.permissionGranted else { input.stop(); clearChord(); setKeysStatus("需要输入监控权限"); return }
        let now = PresentationClock.now()
        if !input.isHealthy && now - lastRetry >= 2 {
            clearChord(); lastRetry = now
            _ = input.start()
        }
        // Keep the passive tap installed while an excluded application is frontmost. The
        // receive gate clears and rejects events before reading any key code/label, avoiding
        // the reinstallation gap when leaving Prosio's own menu or settings.
        guard !excludedApp else { clearChord(); setKeysStatus("当前应用已排除"); return }
        setKeysStatus(input.isHealthy ? "\(preferences.keyDisplayMode.title) · 运行中" : "监听不可用 · 正在重试")
    }
    private func receive(_ type: CGEventType, event: CGEvent) {
        if type == .keyDown { keyboardEvents += 1 }
        guard canShowVisuals, !input.secureInput else { clearChord(keepingPreview: false); return }
        guard state.keysActive, input.permissionGranted, !excludedApp else { clearChord(); return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard !isControlShortcut(code, event.flags) else { clearChord(); return }
        let now = PresentationClock.now()
        switch type {
        case .keyDown:
            guard let label = PresentationInputMonitor.shortcutLabel(event, mode: preferences.keyDisplayMode) else { return }
            previewDeadline = nil
            displayedChords += 1
            chord.press(label: label, keyCode: code, at: now)
        case .keyUp: chord.release(keyCode: code, at: now, linger: preferences.resolvedKeyLinger)
        case .flagsChanged:
            // If the primary key-up was lost, releasing all shortcut modifiers heals the state.
            if event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
               let code = chord.keyCode { chord.release(keyCode: code, at: now, linger: preferences.resolvedKeyLinger) }
        default: return
        }
        overlays.showChord(chord)
    }
    /// Opt-in local diagnostic counts only; never writes key codes, labels, text or app names.
    private func writeDiagnostics() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["PROSIO_PRESENTATION_DIAGNOSTICS_PATH"] else { return }
        let snapshot: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "phase": String(describing: state.phase), "privacyStopped": state.privacyStopped,
            "pointerStatus": pointerStatus, "keysStatus": keysStatus,
            "inputPermission": input.permissionGranted, "inputHealthy": input.isHealthy,
            "secureInput": input.secureInput, "excludedApp": excludedApp,
            "keyboardEvents": keyboardEvents, "displayedChords": displayedChords,
            "chordVisible": chord.label != nil, "keycapWindowVisible": overlays.keycapVisible, "pointerFrames": overlays.pointerFrames,
            "pointerMoves": overlays.pointerMoves, "maximumFrameGap": overlays.maximumFrameGap,
            "awake": awake.isActive
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
    }
    private func setKeysStatus(_ status: String) {
        if keysStatus != status { keysStatus = status }
    }
    private func clearChord(keepingPreview: Bool = true) {
        if keepingPreview, let previewDeadline, PresentationClock.now() < previewDeadline { return }
        previewDeadline = nil
        chord.clear(); overlays.clearKeys()
    }
}
