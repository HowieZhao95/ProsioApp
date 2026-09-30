import AppKit
import AVFoundation
import CoreGraphics
import Observation
import SwiftUI

/// Owns a single recording workflow. Platform callbacks are scoped to the session that
/// installed them, so a late device/writer event cannot mutate another recording.
@Observable
final class RecordingCoordinator {
    let store: RecordingStore
    private let permissions: PermissionsManager
    @ObservationIgnored private let makeEngine: () -> any RecordingEngineControlling
    @ObservationIgnored private let sourceDiscovery: () async throws -> RecordingSourceInventory
    @ObservationIgnored private let authorization: ((RecordingConfiguration) async throws -> Void)?
    @ObservationIgnored private let presentsUI: Bool
    @ObservationIgnored private var sourceRequestID = UUID()
    @ObservationIgnored private var previewGeneration = UUID()
    @ObservationIgnored private var permissionPresentations = Set<UUID>()
    @ObservationIgnored private var engine: (any RecordingEngineControlling)?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var windowDelegate: RecordingWindowDelegate?
    @ObservationIgnored private var controlPanel: NSPanel?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var fatalReason: String?
    @ObservationIgnored private var exportTask: Task<URL, Error>?
    @ObservationIgnored private let editorHandoff: RecordingEditorHandoff
    private var exportedSessionID: UUID?
    private var exportedEditor: RecordingEditor?
    private var exportedFile: URL?
    private var elapsedOrigin: TimeInterval?
    private var pauseOrigin: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    @ObservationIgnored private var regionSelector: RecordingRegionSelector?
    @ObservationIgnored var canBegin: () -> Bool = { true }
    @ObservationIgnored var onActivity: (Bool) -> Void = { _ in }
    private(set) var activeSession: RecordingSessionManifest?
    private(set) var phase: RecordingPhase = .ready
    private(set) var countdown: Int?
    private(set) var message: String? { didSet { updateSelectionPanelSize() } }
    private(set) var sourceAvailability: [String: Bool] = [:]
    private(set) var inventory: RecordingSourceInventory?
    private(set) var loadingSources = false
    private(set) var exporting = false
    private(set) var openingEditor = false
    private(set) var exportMessage: String?
    private(set) var permissionRecovery: RecordingPermissionRecovery?
    @ObservationIgnored private var desktopSelection: RecordingDesktopSelectionController?
    @ObservationIgnored private var selectionPanel: NSPanel?
    @ObservationIgnored private var completionPanel: NSPanel?
    @ObservationIgnored private var cameraPanels: [String: NSPanel] = [:]
    @ObservationIgnored private let cameraPreview: RecordingCameraPreviewController
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var previewShutdownTask: Task<Void, Never>?
    private(set) var closingSelection = false
    private(set) var completionAvailable = false
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var immersiveRecording = false
    private var hiddenPreviews = Set<String>()
    @ObservationIgnored private var lastPanelScreenID: UInt32?
    private(set) var selectionActive = false
    private(set) var selectionTargetReady = false
    private(set) var cameraPreviewStatuses: [String: RecordingCameraPreviewStatus] = [:]
    private(set) var previewRevision = 0
    var selectedSessionID: UUID?
    var screenMode = "display"
    var displayID: UInt32 = 0
    var windowID: UInt32 = 0
    var region: RecordingRegion?
    var cameraOneID = ""
    var cameraTwoID = ""
    var microphoneID = ""
    var includeMicrophone = true
    var includeSystemAudio = true
    var showsCursor = true

    var isBusy: Bool {
        switch phase {
        case .preparing, .recording, .paused, .finalizing: true
        default: false
        }
    }

    var blocksOtherCapture: Bool { isBusy || selectionActive || closingSelection }

    var isCapturing: Bool { phase == .recording || phase == .paused }
    var elapsedSeconds: TimeInterval {
        guard let elapsedOrigin else { return 0 }
        return max(0, (pauseOrigin ?? ProcessInfo.processInfo.systemUptime) - elapsedOrigin - pausedDuration)
    }
    var selectedSession: RecordingSessionManifest? {
        store.sessions.first { $0.id == selectedSessionID }
    }

    init(root: URL, permissions: PermissionsManager,
         makeEngine: @escaping () -> any RecordingEngineControlling = { RecordingEngine() },
         inventory: RecordingSourceInventory? = nil,
         editorHandoff: RecordingEditorHandoff = RecordingEditorHandoff(),
         sourceDiscovery: @escaping () async throws -> RecordingSourceInventory = { try await RecordingEngine.discoverSources() },
         cameraPreview: RecordingCameraPreviewController = RecordingCameraPreviewController(),
         authorization: ((RecordingConfiguration) async throws -> Void)? = nil,
         presentsUI: Bool = true) {
        store = RecordingStore(root: root)
        self.permissions = permissions
        self.makeEngine = makeEngine
        self.inventory = inventory
        self.editorHandoff = editorHandoff
        self.sourceDiscovery = sourceDiscovery
        self.cameraPreview = cameraPreview
        self.authorization = authorization
        self.presentsUI = presentsUI
        restorePreferences()
    }

    func recoverSavedSessions() async {
        for session in store.sessions {
            guard activeSession?.id != session.id else { continue }
            let recovered = await RecordingRecovery.recover(session, in: store.directory(for: session.id))
            guard activeSession?.id != session.id else { continue }
            if recovered != session {
                do { try store.save(recovered) }
                catch { message = "恢复清单保存失败，原片仍保留：\(error.localizedDescription)" }
            }
        }
    }

    func refreshSources() async {
        guard !loadingSources, !isBusy else { return }
        let request = UUID()
        sourceRequestID = request
        loadingSources = true
        defer { if sourceRequestID == request { loadingSources = false } }
        do {
            let discovered = try await sourceDiscovery()
            guard sourceRequestID == request, !Task.isCancelled else { return }
            inventory = discovered
            if displayID == 0 { displayID = inventory?.displays.first?.id ?? 0 }
            if windowID == 0 { windowID = inventory?.windows.first?.id ?? 0 }
            if microphoneID.isEmpty { microphoneID = inventory?.microphones.first?.id ?? "" }
            message = nil
            permissionRecovery = nil
        } catch {
            guard sourceRequestID == request, !Task.isCancelled else { return }
            message = "无法取得录制来源：\(error.localizedDescription)"
            permissions.refresh()
            permissionRecovery = CGPreflightScreenCaptureAccess() ? nil : .screen
        }
    }

    func showWindow(sessionID: UUID? = nil) {
        guard presentsUI else { return }
        if let sessionID { selectedSessionID = sessionID }
        else if selectedSession == nil { selectedSessionID = store.sessions.first?.id }
        if window == nil {
            let view = RecordingWorkspaceView(coordinator: self)
            let panel = NSWindow(contentViewController: NSHostingController(rootView: view))
            panel.title = "屏幕录制"
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            panel.setContentSize(NSSize(width: 900, height: 640))
            panel.minSize = NSSize(width: 760, height: 560)
            panel.isReleasedWhenClosed = false
            let delegate = RecordingWindowDelegate { [weak self] in self?.cancelPreparation() }
            windowDelegate = delegate
            panel.delegate = delegate
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task { await refreshSources() }
    }

    func showSelection() {
        guard !isBusy, !closingSelection, canBegin() else { return }
        if selectionActive { selectionPanel?.orderFrontRegardless(); return }
        closeCompletion()
        window?.orderOut(nil)
        sourceRequestID = UUID()
        loadingSources = false
        selectionActive = true
        selectionTargetReady = false
        immersiveRecording = false
        hiddenPreviews.removeAll()
        onActivity(true)
        let generation = UUID()
        selectionGeneration = generation
        showSelectionPanel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshSelectionSources()
            guard self.selectionActive, self.selectionGeneration == generation else { return }
        }
    }

    func refreshSelectionSources() async {
        guard selectionActive, !isBusy else { return }
        let generation = selectionGeneration
        await refreshSources()
        guard selectionActive, selectionGeneration == generation, let inventory, permissionRecovery != .screen else { return }
        if !presentsUI { syncCameraPreviews(); return }
        if let desktopSelection { desktopSelection.updateInventory(inventory) }
        else {
            let selector = RecordingDesktopSelectionController(inventory: inventory,
                mode: RecordingSelectionMode(rawValue: screenMode) ?? .display,
                onSelection: { [weak self] in self?.updateSelectionTarget($0) },
                onCancel: { [weak self] in self?.dismissSelection() },
                onConfirm: { [weak self] in self?.begin() })
            desktopSelection = selector
            selector.present()
            // The desktop starts in pointer-selected display mode, never a persisted region.
            if screenMode == "region" { region = nil }
        }
        selectionPanel?.makeKeyAndOrderFront(nil)
        syncCameraPreviews()
    }

    func updateSelectionTarget(_ target: RecordingScreenTarget?) {
        guard !isBusy else { return }
        selectionTargetReady = target != nil
        guard let target else { return }
        switch target {
        case .display(let id): displayID = id; screenMode = "display"
        case .window(let id): windowID = id; screenMode = "window"
        case .region(let id, let rect): displayID = id; region = rect; screenMode = "region"
        }
        if let screen = desktopSelection?.currentScreen {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
            if lastPanelScreenID != id {
                lastPanelScreenID = id
                positionBottom(selectionPanel, on: screen)
                positionCameraPanels(on: screen)
            }
        }
    }

    func setSelectionMode(_ mode: RecordingSelectionMode) {
        guard !isBusy, screenMode != mode.rawValue else { return }
        screenMode = mode.rawValue
        selectionTargetReady = false
        region = nil
        desktopSelection?.setMode(mode)
    }

    func dismissSelection() {
        guard selectionActive else { return }
        selectionActive = false
        selectionTargetReady = false
        selectionGeneration = UUID()
        sourceRequestID = UUID()
        loadingSources = false
        previewGeneration = UUID()
        selectionTask?.cancel()
        selectionTask = nil
        cancelPreparation()
        desktopSelection?.dismiss()
        desktopSelection = nil
        selectionPanel?.orderOut(nil)
        selectionPanel = nil
        previewTask?.cancel()
        closeCameraPanels()
        closingSelection = true
        previewShutdownTask = Task { [weak self] in
            guard let self else { return }
            if let previewTask = self.previewTask { await previewTask.value }
            await self.cameraPreview.stopAll()
            self.closingSelection = false
            self.previewShutdownTask = nil
            self.onActivity(self.blocksOtherCapture)
        }
    }

    var selectedCameraIDs: [String] { [cameraOneID, cameraTwoID].filter { !$0.isEmpty } }
    var selectedCameraSources: [RecordingSource] {
        let ids = selectedCameraIDs
        return ids.compactMap { id in inventory?.cameras.first { $0.id == id } }
    }
    func isCameraSelected(_ id: String) -> Bool { cameraOneID == id || cameraTwoID == id }
    func toggleCamera(_ id: String) {
        guard !isBusy, isCameraSelected(id) || inventory?.cameras.contains(where: { $0.id == id }) == true else { return }
        if cameraOneID == id { cameraOneID = cameraTwoID; cameraTwoID = "" }
        else if cameraTwoID == id { cameraTwoID = "" }
        else if cameraOneID.isEmpty { cameraOneID = id }
        else if cameraTwoID.isEmpty { cameraTwoID = id }
        else { return }
        hiddenPreviews.remove(id)
        if selectedCameraIDs.isEmpty, permissionRecovery == .camera { permissionRecovery = nil; message = nil }
        syncCameraPreviews()
    }
    func clearCameras() {
        guard !isBusy else { return }
        cameraOneID = ""; cameraTwoID = ""
        if permissionRecovery == .camera { permissionRecovery = nil; message = nil }
        syncCameraPreviews()
    }
    func microphoneName(_ source: RecordingSource) -> String {
        source.name.hasPrefix("CADefaultDeviceAggregate-") ? "系统默认麦克风" : source.name
    }
    func cameraPreviewSession(for id: String) -> AVCaptureSession? {
        _ = previewRevision
        if phase == .preparing { return nil }
        if isCapturing || phase == .finalizing {
            return (engine as? any RecordingCameraPreviewProviding)?.previewSession(for: id)
        }
        return selectionActive ? cameraPreview.session(for: id) : nil
    }
    func previewStatusText(for id: String) -> String? {
        if isCapturing || phase == .finalizing {
            return sourceAvailability[id] == false ? "连接中，其他来源继续录制" : cameraPreviewSession(for: id) == nil ? "等待画面" : nil
        }
        switch cameraPreviewStatuses[id] ?? .starting {
        case .idle, .starting: return "正在连接摄像头…"
        case .live: return nil
        case .disconnected: return "等待摄像头重新连接…"
        case .failed(let reason): return reason
        }
    }
    var previewsHidden: Bool { !hiddenPreviews.isEmpty }
    func closeCameraPreview(_ id: String) {
        if isBusy { hiddenPreviews.insert(id); cameraPanels[id]?.orderOut(nil) }
        else { toggleCamera(id) }
    }
    func togglePreviewVisibility() {
        if hiddenPreviews.isEmpty { hiddenPreviews.formUnion(selectedCameraSources.map(\.id)) }
        else { hiddenPreviews.removeAll() }
        syncCameraPanels()
    }
    func closeCompletion() { completionPanel?.orderOut(nil); completionPanel = nil; completionAvailable = false }

    private func syncCameraPreviews() {
        guard selectionActive, !isBusy else { return }
        syncCameraPanels()
        cameraPreview.onStatus = { [weak self] id, status in
            guard let self, self.selectionActive, self.selectedCameraIDs.contains(id) else { return }
            self.cameraPreviewStatuses[id] = status
            self.previewRevision += 1
        }
        previewTask?.cancel()
        let generation = UUID()
        previewGeneration = generation
        let sources = selectedCameraSources
        previewTask = Task { [weak self] in
            guard let self else { return }
            guard self.selectionActive, self.previewGeneration == generation, !Task.isCancelled else { return }
            let awaitingPermission = !sources.isEmpty && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
            let presentation = awaitingPermission ? self.beginPermissionPresentation() : nil
            defer { if let presentation { self.endPermissionPresentation(presentation) } }
            do { try await self.cameraPreview.update(sources: sources) }
            catch {
                if !(error is CancellationError), !Task.isCancelled, self.selectionActive, self.previewGeneration == generation {
                    self.message = error.localizedDescription
                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied { self.permissionRecovery = .camera }
                }
            }
        }
    }

    private func syncCameraPanels() {
        guard presentsUI else { return }
        let sources = selectedCameraSources
        let desired = Set(sources.map(\.id))
        for id in Array(cameraPanels.keys) where !desired.contains(id) {
            cameraPanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for source in sources {
            if cameraPanels[source.id] == nil {
                let panel = makeOverlayPanel(size: RecordingCameraPreviewStyle.panelSize)
                panel.title = "摄像头预览 · \(source.name)"
                panel.hasShadow = false // The rounded card draws one consistent shadow inside its padding.
                panel.isMovableByWindowBackground = true
                panel.contentView = NSHostingView(rootView: RecordingCameraPreviewCard(coordinator: self, source: source))
                cameraPanels[source.id] = panel
                if let screen = desktopSelection?.currentScreen ?? pointerScreen(),
                   let index = sources.firstIndex(where: { $0.id == source.id }) {
                    positionCameraPanel(panel, index: index, on: screen)
                }
            }
            cameraPanels[source.id]?.level = isBusy ? .floating : NSWindow.Level(rawValue: RecordingDesktopSelectionController.overlayLevel.rawValue + 1)
            if !permissionPresentations.isEmpty || hiddenPreviews.contains(source.id) { cameraPanels[source.id]?.orderOut(nil) }
            else { cameraPanels[source.id]?.orderFrontRegardless() }
        }
    }
    private func positionCameraPanels(on screen: NSScreen?) {
        guard let screen else { return }
        for (index, source) in selectedCameraSources.enumerated() {
            if let panel = cameraPanels[source.id] { positionCameraPanel(panel, index: index, on: screen) }
        }
    }
    func cameraPreviewOrigin(for id: String) -> NSPoint? { cameraPanels[id]?.frame.origin }
    func moveCameraPreview(_ id: String, to origin: NSPoint) {
        cameraPanels[id]?.setFrameOrigin(origin)
    }
    private func positionCameraPanel(_ panel: NSPanel, index: Int, on screen: NSScreen) {
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 18,
            y: screen.visibleFrame.maxY - panel.frame.height - 18 - CGFloat(index) * (panel.frame.height + 12)))
    }
    private func closeCameraPanels() {
        previewRefreshTask?.cancel(); previewRefreshTask = nil
        for panel in cameraPanels.values { panel.orderOut(nil); panel.contentView = nil }
        cameraPanels.removeAll()
    }
    private func makeOverlayPanel(size: CGSize) -> NSPanel {
        let panel = RecordingFloatingPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: RecordingDesktopSelectionController.overlayLevel.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
    private func pointerScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
    private func positionBottom(_ panel: NSPanel?, on screen: NSScreen?) {
        guard let panel, let screen else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.minY + 24))
    }
    private func beginPermissionPresentation() -> UUID {
        let token = UUID()
        permissionPresentations.insert(token)
        updatePermissionPresentation()
        return token
    }
    private func endPermissionPresentation(_ token: UUID) {
        permissionPresentations.remove(token)
        updatePermissionPresentation()
    }
    private func updatePermissionPresentation() {
        guard selectionActive, presentsUI else { return }
        let hidden = !permissionPresentations.isEmpty
        desktopSelection?.setTemporarilyHidden(hidden)
        if hidden {
            selectionPanel?.orderOut(nil)
            for panel in cameraPanels.values { panel.orderOut(nil) }
        } else {
            selectionPanel?.makeKeyAndOrderFront(nil)
            syncCameraPanels()
        }
    }
    private func showSelectionPanel() {
        guard presentsUI else { return }
        let panel = makeOverlayPanel(size: CGSize(width: 510, height: message == nil ? 74 : 142))
        panel.contentView = NSHostingView(rootView: RecordingSelectionToolbarView(coordinator: self)
            .frame(maxHeight: .infinity, alignment: .top))
        selectionPanel = panel
        positionBottom(panel, on: pointerScreen())
        panel.makeKeyAndOrderFront(nil)
    }
    private func updateSelectionPanelSize() {
        guard let selectionPanel else { return }
        let height: CGFloat = message == nil ? 74 : 142
        selectionPanel.setFrame(CGRect(x: selectionPanel.frame.minX, y: selectionPanel.frame.minY,
                                      width: 510, height: height), display: true)
    }
    private func showCompletion() {
        completionAvailable = true
        guard presentsUI else { return }
        let panel = makeOverlayPanel(size: CGSize(width: 370, height: 64))
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: RecordingCompletionView(coordinator: self))
        completionPanel = panel
        positionBottom(panel, on: pointerScreen())
        panel.orderFrontRegardless()
    }

    func configuration() throws -> RecordingConfiguration {
        guard let inventory else { throw RecordingWorkflowError.message("请先刷新录制来源。") }
        let target: RecordingScreenTarget
        switch screenMode {
        case "window":
            guard inventory.windows.contains(where: { $0.id == windowID }) else {
                throw RecordingWorkflowError.message("所选窗口已关闭，请重新选择。")
            }
            target = .window(windowID)
        case "region":
            guard inventory.displays.contains(where: { $0.id == displayID }), let region else {
                throw RecordingWorkflowError.message("请在所选显示器上框选录制区域。")
            }
            target = .region(displayID: displayID, rect: region)
        default:
            guard inventory.displays.contains(where: { $0.id == displayID }) else {
                throw RecordingWorkflowError.message("所选显示器不可用，请重新选择。")
            }
            target = .display(displayID)
        }
        let cameraIDs = [cameraOneID, cameraTwoID].filter { !$0.isEmpty }
        guard Set(cameraIDs).count == cameraIDs.count else {
            throw RecordingWorkflowError.message("两个机位需要选择不同的摄像头。")
        }
        let cameras = try cameraIDs.map { id in
            guard let source = inventory.cameras.first(where: { $0.id == id }) else {
                throw RecordingWorkflowError.message("所选摄像头不可用，请刷新来源或关闭这个机位。")
            }
            return source
        }
        let mic: RecordingSource?
        if includeMicrophone {
            guard let source = inventory.microphones.first(where: { $0.id == microphoneID }) else {
                throw RecordingWorkflowError.message("所选麦克风不可用，请重新选择或关闭麦克风。")
            }
            mic = source
        } else { mic = nil }
        return RecordingConfiguration(screenTarget: target, cameras: cameras, microphone: mic,
                                      capturesSystemAudio: includeSystemAudio, showsCursor: showsCursor)
    }

    func begin() {
        guard !isBusy, preparationTask == nil, !selectionActive || selectionTargetReady else { return }
        guard desktopSelection?.validateSelection() != false else {
            message = "录制目标已变化，请重新选择。"
            return
        }
        do {
            let configuration = try configuration()
            guard canBegin() else {
                throw RecordingWorkflowError.message("请先结束语音输入、截图或录音转写，再开始录屏。")
            }
            preparationTask = Task { await start(configuration: configuration) }
        } catch { message = error.localizedDescription }
    }

    /// Callable with an injected engine for lifecycle acceptance; no UI or inventory needed.
    func start(configuration: RecordingConfiguration, countdownSeconds: Int = 3,
               requestPermissions: Bool = true) async {
        guard !isBusy, canBegin() else { return }
        phase = .preparing
        stopRequested = false
        fatalReason = nil
        onActivity(true)
        message = nil
        permissionRecovery = nil
        exportMessage = nil
        var created: RecordingSessionManifest?
        do {
            previewTask?.cancel()
            if let previewTask { await previewTask.value }
            await cameraPreview.stopAll()
            try Task.checkCancellation()
            if requestPermissions {
                if let authorization { try await authorization(configuration) }
                else { try await authorize(configuration) }
            }
            try Task.checkCancellation()
            for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
                countdown = remaining
                desktopSelection?.setCountdown(remaining)
                try await Task.sleep(for: .seconds(1))
            }
            countdown = nil
            try Task.checkCancellation()
            let session = try store.create(configuration: configuration)
            created = session
            activeSession = session
            selectedSessionID = session.id
            sourceAvailability = Dictionary(uniqueKeysWithValues: session.sources.map { ($0.id, true) })
            let engine = makeEngine()
            self.engine = engine
            let sessionID = session.id
            engine.onSegment = { [weak self] segment in self?.append(segment, sessionID: sessionID) }
            engine.onWarning = { [weak self] warning in self?.warn(warning, sessionID: sessionID) }
            engine.onSourceStatus = { [weak self] sourceID, available in
                guard self?.activeSession?.id == sessionID else { return }
                self?.sourceAvailability[sourceID] = available
            }
            engine.onFailure = { [weak self] reason in
                guard self?.activeSession?.id == sessionID else { return }
                self?.fatalReason = reason
                self?.warn(reason, sessionID: sessionID)
                Task { await self?.stop() }
            }
            try await engine.start(configuration: configuration, directory: store.directory(for: sessionID))
            try Task.checkCancellation()
            phase = .recording
            selectionTargetReady = false
            elapsedOrigin = ProcessInfo.processInfo.systemUptime
            pausedDuration = 0
            pauseOrigin = nil
            try updateActive { $0.phase = .recording }
            persistPreferences()
            if requestPermissions {
                immersiveRecording = selectionActive
                selectionActive = false
                selectionTargetReady = false
                desktopSelection?.dismiss(); desktopSelection = nil
                selectionPanel?.orderOut(nil); selectionPanel = nil
                if presentsUI { showControlPanel(); syncCameraPanels() }
                previewRefreshTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, !Task.isCancelled, self.isBusy else { return }
                        self.previewRevision += 1
                    }
                }
            }
        } catch {
            // Keep callbacks attached until writers finish so any completed raw file is retained.
            try? await engine?.stop()
            if activeSession == nil { activeSession = created }
            if activeSession != nil {
                try? updateActive {
                    $0.phase = $0.segments.isEmpty ? .failed : .interrupted
                    $0.endedAt = .now
                    if !(error is CancellationError) { $0.warnings.append(error.localizedDescription) }
                }
            }
            phase = .failed
            message = error is CancellationError ? "已取消准备录制。" : error.localizedDescription
            releaseEngine()
            desktopSelection?.setCountdown(nil)
            if selectionActive {
                selectionTargetReady = (try? self.configuration()) != nil
                syncCameraPreviews()
            }
        }
        countdown = nil
        preparationTask = nil
    }

    func cancelPreparation() {
        guard phase == .preparing else { return }
        preparationTask?.cancel()
    }

    func togglePause() async {
        guard let engine, phase == .recording || phase == .paused else { return }
        let wasPaused = phase == .paused
        // Serialize buttons while a segment is being finalized.
        phase = .finalizing
        do {
            if wasPaused { try await engine.resume() } else { try await engine.pause() }
            if wasPaused {
                if let pauseOrigin { pausedDuration += ProcessInfo.processInfo.systemUptime - pauseOrigin }
                pauseOrigin = nil
            } else { pauseOrigin = ProcessInfo.processInfo.systemUptime }
            phase = wasPaused ? .recording : .paused
            try updateActive { $0.phase = phase }
            if stopRequested { await stop() }
        } catch {
            message = "无法切换录制状态：\(error.localizedDescription)"
            phase = wasPaused ? .paused : .recording
            await stop()
        }
    }

    func stop() async {
        guard let engine else { return }
        if phase == .finalizing { stopRequested = true; return }
        phase = .finalizing
        countdown = nil
        do {
            // A manifest write failure must never bypass shutting down live capture devices.
            do { try updateActive { $0.phase = .finalizing } }
            catch { fatalReason = "录制清单保存失败：\(error.localizedDescription)" }
            try await engine.stop()
            try updateActive {
                $0.endedAt = .now
                $0.phase = fatalReason != nil ? .interrupted : $0.segments.isEmpty ? .failed : .ready
            }
            phase = activeSession?.phase ?? .failed
            message = phase == .ready
                ? (activeSession?.warnings.isEmpty == false
                   ? "录制已保存，部分来源有提示，请在素材中查看。"
                   : "录制已保存，可预览或交给剪辑软件。")
                : fatalReason.map { "录制已中断，已完成原片保留。\($0)" }
                ?? "没有取得可播放片段，请检查录制来源。"
        } catch {
            try? updateActive {
                $0.phase = .interrupted
                $0.endedAt = .now
                $0.warnings.append(error.localizedDescription)
            }
            phase = .interrupted
            message = "录制已结束；已完成原片保留。\(error.localizedDescription)"
        }
        releaseEngine()
        if immersiveRecording { immersiveRecording = false; showCompletion() }
        else if window != nil {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func flushForTermination() async {
        dismissSelection()
        if let previewShutdownTask { await previewShutdownTask.value }
        previewTask?.cancel()
        if let previewTask { await previewTask.value }
        await cameraPreview.stopAll()
        preparationTask?.cancel()
        if let preparationTask { await preparationTask.value }
        if isCapturing { await stop() }
        // A pause/stop operation already in flight must finish before the application exits.
        while phase == .finalizing { try? await Task.sleep(for: .milliseconds(50)) }
        if isCapturing { await stop() }
    }

    private func authorize(_ configuration: RecordingConfiguration) async throws {
        permissions.refresh()
        let needsAuthorization = !CGPreflightScreenCaptureAccess()
            || (configuration.microphone != nil && permissions.statuses[.microphone] != .granted)
            || (!configuration.cameras.isEmpty && AVCaptureDevice.authorizationStatus(for: .video) != .authorized)
        let presentation = needsAuthorization ? beginPermissionPresentation() : nil
        defer { if let presentation { endPermissionPresentation(presentation) } }
        try Task.checkCancellation()
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else {
                permissionRecovery = .screen
                throw RecordingWorkflowError.message("请在系统设置中允许 Prosio 录制屏幕，再重新开始。")
            }
        }
        try Task.checkCancellation()
        if configuration.microphone != nil, permissions.statuses[.microphone] != .granted {
            await permissions.request(.microphone)
            try Task.checkCancellation()
            guard permissions.statuses[.microphone] == .granted else {
                permissionRecovery = .microphone
                throw RecordingWorkflowError.message("请允许麦克风访问，或关闭麦克风后开始录屏。")
            }
        }
        try Task.checkCancellation()
        if !configuration.cameras.isEmpty {
            var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            if !allowed { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            try Task.checkCancellation()
            guard allowed else {
                permissionRecovery = .camera
                throw RecordingWorkflowError.message("请允许摄像头访问，或关闭机位后开始录屏。")
            }
        }
    }

    func openPermissions() {
        switch permissionRecovery {
        case .microphone: permissions.openSystemSettings(for: .microphone)
        case .camera:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func selectRegion() {
        guard !isBusy else { return }
        guard canBegin() else {
            permissionRecovery = nil
            message = "请先结束语音输入、截图或录音转写，再选择录屏区域。"
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { message = "所选显示器不可用，请重新选择。"; return }
        window?.orderOut(nil)
        let selector = RecordingRegionSelector(screen: screen) { [weak self] rect in
            guard let self else { return }
            if let rect {
                region = RecordingRegion(x: rect.minX, y: screen.frame.height - rect.maxY,
                                         width: rect.width, height: rect.height)
            }
            regionSelector = nil
            window?.makeKeyAndOrderFront(nil)
        }
        regionSelector = selector
        selector.begin()
    }

    func reveal(_ session: RecordingSessionManifest) {
        NSWorkspace.shared.open(store.directory(for: session.id))
    }

    func export(_ session: RecordingSessionManifest, editor: RecordingEditor) async {
        guard !exporting, !session.segments.isEmpty else { return }
        exporting = true
        defer { exporting = false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        panel.message = "将在所选文件夹中保存独立原片与\(editor.title)交接文件。"
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        exportMessage = nil
        do {
            let sourceDirectory = store.directory(for: session.id)
            let task = Task {
                try await RecordingProjectExporter().export(
                    session: session, sourceDirectory: sourceDirectory,
                    destination: destination.appendingPathComponent("录制-\(session.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(6))", isDirectory: true), editor: editor)
            }
            exportTask = task
            defer { exportTask = nil }
            let output = try await task.value
            exportedSessionID = session.id
            exportedEditor = editor
            exportedFile = output
            exportMessage = "交接文件已保存。请在\(editor.title)中导入并检查机位和音频。"
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch is CancellationError { exportMessage = "导出已取消，原片仍保留。" }
        catch { exportMessage = "导出未完成，可重试：\(error.localizedDescription)" }
    }

    func cancelExport() { exportTask?.cancel() }

    func hasExport(for sessionID: UUID, editor: RecordingEditor) -> Bool {
        exportedSessionID == sessionID && exportedEditor == editor && exportedFile != nil
    }

    func openExport(for sessionID: UUID, editor: RecordingEditor) async {
        guard !exporting, !openingEditor, hasExport(for: sessionID, editor: editor), let file = exportedFile else { return }
        openingEditor = true
        defer { openingEditor = false }
        do {
            let receipt = try await editorHandoff.open(exportedFile: file, editor: editor)
            exportMessage = receipt.message
        } catch is CancellationError {
            exportMessage = "打开已取消，交接文件仍保留。"
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func append(_ segment: RecordingSegment, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        do {
            try updateActive {
                guard !$0.segments.contains(where: { $0.id == segment.id }) else { return }
                $0.segments.append(segment)
            }
        } catch {
            message = "无法保存录制清单：\(error.localizedDescription)"
            Task { await self.stop() }
        }
    }

    private func warn(_ warning: String, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        message = warning
        try? updateActive {
            if !$0.warnings.contains(warning) { $0.warnings.append(warning) }
        }
    }

    private func updateActive(_ update: (inout RecordingSessionManifest) -> Void) throws {
        guard var session = activeSession else { return }
        update(&session)
        // Publish the current media state even if persistence fails, so a later retry
        // doesn't lose a finalized segment from memory.
        activeSession = session
        try store.save(session)
    }

    private func releaseEngine() {
        controlPanel?.orderOut(nil)
        controlPanel = nil
        closeCameraPanels()
        engine?.onSegment = nil
        engine?.onWarning = nil
        engine?.onSourceStatus = nil
        engine?.onFailure = nil
        engine = nil
        activeSession = nil
        sourceAvailability = [:]
        elapsedOrigin = nil
        pauseOrigin = nil
        onActivity(blocksOtherCapture)
    }

    private func showControlPanel() {
        window?.orderOut(nil)
        let panel = makeOverlayPanel(size: CGSize(width: 248, height: 60))
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: RecordingCompactControlView(coordinator: self))
        positionBottom(panel, on: pointerScreen())
        controlPanel = panel
        panel.orderFrontRegardless()
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "recordingPreferences"),
              let prefs = try? JSONDecoder().decode(RecordingPreferences.self, from: data) else { return }
        displayID = prefs.displayID
        cameraOneID = prefs.cameraOneID
        cameraTwoID = prefs.cameraTwoID
        microphoneID = prefs.microphoneID
        includeMicrophone = prefs.includeMicrophone
        includeSystemAudio = prefs.includeSystemAudio
        showsCursor = prefs.showsCursor
        screenMode = prefs.screenMode ?? "display"
        windowID = prefs.windowID ?? 0
        region = prefs.region
    }

    private func persistPreferences() {
        let prefs = RecordingPreferences(displayID: displayID, cameraOneID: cameraOneID,
                                         cameraTwoID: cameraTwoID, microphoneID: microphoneID,
                                         includeMicrophone: includeMicrophone,
                                         includeSystemAudio: includeSystemAudio, showsCursor: showsCursor,
                                         screenMode: screenMode, windowID: windowID, region: region)
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: "recordingPreferences")
        }
    }
}

nonisolated private struct RecordingPreferences: Codable {
    var displayID: UInt32
    var cameraOneID: String
    var cameraTwoID: String
    var microphoneID: String
    var includeMicrophone: Bool
    var includeSystemAudio: Bool
    var showsCursor: Bool
    var screenMode: String?
    var windowID: UInt32?
    var region: RecordingRegion?
}

nonisolated enum RecordingPermissionRecovery {
    case screen, microphone, camera
    var title: String {
        switch self {
        case .screen: "屏幕录制权限设置…"
        case .microphone: "麦克风权限设置…"
        case .camera: "摄像头权限设置…"
        }
    }
}

nonisolated enum RecordingWorkflowError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Borderless controls must accept keyboard focus, including before source discovery succeeds.
private final class RecordingFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
