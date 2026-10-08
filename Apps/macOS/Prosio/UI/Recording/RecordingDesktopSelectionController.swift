import AppKit
import CoreGraphics

nonisolated enum RecordingSelectionMode: String {
    case display, window, region
}

/// Window ordering comes from Quartz, never from the alphabetically sorted source inventory.
nonisolated struct RecordingDesktopWindowHit: Sendable {
    let id: UInt32
    let frame: CGRect
    let ownerPID: Int32
    let layer: Int
    let alpha: Double
}

nonisolated enum RecordingDesktopKeyboardAction {
    case passThrough, consume, cancel, confirm

    static func resolve(keyCode: UInt16, hasSelection: Bool, isPresented: Bool, isHidden: Bool,
                        isMenuTracking: Bool, isRegionDragging: Bool, isCountingDown: Bool) -> Self {
        guard isPresented, !isHidden, !isMenuTracking else { return .passThrough }
        if keyCode == 53 { return .cancel }
        if keyCode == 36 || keyCode == 76 {
            return hasSelection && !isRegionDragging && !isCountingDown ? .confirm : .consume
        }
        return .passThrough
    }
}

nonisolated enum RecordingDesktopSelectionGeometry {
    static let minimumRegionSize = CGSize(width: 16, height: 16)

    static func window(at capturePoint: CGPoint, frontToBack: [RecordingDesktopWindowHit],
                       available: [RecordingWindowChoice], excludingIDs: Set<UInt32> = [],
                       excludingPID: Int32) -> RecordingDesktopWindowHit? {
        let availableIDs = Set(available.map(\.id))
        return frontToBack.first {
            availableIDs.contains($0.id) && !excludingIDs.contains($0.id) && $0.ownerPID != excludingPID &&
            $0.layer == 0 && $0.alpha > 0 && $0.frame.width > 1 && $0.frame.height > 1 &&
            $0.frame.contains(capturePoint)
        }
    }

    static func liveWindow(id: UInt32, frontToBack: [RecordingDesktopWindowHit], available: [RecordingWindowChoice],
                           excludingPID: Int32) -> RecordingDesktopWindowHit? {
        guard available.contains(where: { $0.id == id }) else { return nil }
        return frontToBack.first {
            $0.id == id && $0.ownerPID != excludingPID && $0.layer == 0 && $0.alpha > 0 &&
            $0.frame.width > 1 && $0.frame.height > 1
        }
    }

    static func region(_ overlayRect: CGRect, display: RecordingDisplayChoice, screenFrame: CGRect) -> RecordingScreenTarget? {
        guard [overlayRect.minX, overlayRect.minY, overlayRect.width, overlayRect.height].allSatisfy(\.isFinite) else { return nil }
        let transform = CaptureDisplayTransform(captureFrame: display.frame, overlayFrame: screenFrame)
        let rect = overlayRect.standardized.intersection(transform.overlayLocalBounds)
        guard !rect.isNull, rect.width >= minimumRegionSize.width, rect.height >= minimumRegionSize.height else { return nil }
        let origin = transform.captureLocalPoint(fromOverlayLocalPoint: rect.origin)
        let end = transform.captureLocalPoint(fromOverlayLocalPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        let captureRect = CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
            .intersection(transform.captureLocalBounds)
        guard !captureRect.isEmpty else { return nil }
        return .region(displayID: display.id, rect: RecordingRegion(x: captureRect.minX, y: captureRect.minY,
                                                                   width: captureRect.width, height: captureRect.height))
    }

    /// Use the existing point transform without integer inflation on repeated display-layout rebuilds.
    static func overlayRect(for region: RecordingRegion, display: RecordingDisplayChoice, screenFrame: CGRect) -> CGRect {
        let transform = CaptureDisplayTransform(captureFrame: display.frame, overlayFrame: screenFrame)
        let origin = transform.overlayLocalPoint(fromCaptureLocalPoint: CGPoint(x: region.x, y: region.y))
        let end = transform.overlayLocalPoint(fromCaptureLocalPoint: CGPoint(x: region.x + region.width, y: region.y + region.height))
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y).intersection(transform.overlayLocalBounds)
    }

    static func handle(at point: CGPoint, in rect: CGRect, radius: CGFloat = 9) -> CaptureResizeHandle? {
        let hitRadius = min(radius, min(rect.width, rect.height) / 4)
        return CaptureResizeHandle.allCases.min {
            distance(point, $0.position(in: rect)) < distance(point, $1.position(in: rect))
        }.flatMap { distance(point, $0.position(in: rect)) <= hitRadius ? $0 : nil }
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }
}

/// Pure interaction state also protects the last target when a floating control receives the pointer.
nonisolated struct RecordingDesktopSelectionState {
    private(set) var target: RecordingScreenTarget?
    private(set) var locked = false

    mutating func hover(_ candidate: RecordingScreenTarget?, overControls: Bool = false) {
        guard !locked, !overControls else { return }
        target = candidate
    }

    mutating func lock() { if target != nil { locked = true } }
    mutating func click(_ candidate: RecordingScreenTarget?) { target = candidate; locked = candidate != nil }
    mutating func selectRegion(_ candidate: RecordingScreenTarget?) { target = candidate; locked = candidate != nil }
    mutating func reset() { target = nil; locked = false }
}

/// Live, transparent AppKit panels over the real desktop. No screenshot or capture session is created.
@MainActor
final class RecordingDesktopSelectionController {
    /// Covers desktop windows; toolbar/cameras sit above it and native popup menus remain higher.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private struct Surface {
        let screen: NSScreen
        let display: RecordingDisplayChoice
        let panel: RecordingDesktopSelectionPanel
        let view: RecordingDesktopSelectionView
    }

    private var inventory: RecordingSourceInventory
    private var mode: RecordingSelectionMode
    private let onSelection: (RecordingScreenTarget?) -> Void
    private let onCancel: () -> Void
    private let onConfirm: () -> Void
    private var surfaces: [Surface] = []
    private var state = RecordingDesktopSelectionState()
    private var activeDisplayID: UInt32?
    private var windowFrame: CGRect?
    private var regionRect: CGRect?
    private var lastPublished: RecordingScreenTarget?
    private var countdown: Int?
    private var isPresented = false
    private var isTemporarilyHidden = false
    private var rebuildPending = false
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = Set<ObjectIdentifier>()

    var currentScreen: NSScreen? {
        surfaces.first { $0.display.id == activeDisplayID }?.screen ??
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    init(inventory: RecordingSourceInventory, mode: RecordingSelectionMode,
         onSelection: @escaping (RecordingScreenTarget?) -> Void,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.inventory = inventory
        self.mode = mode
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    func present() {
        guard !isPresented else { return }
        isPresented = true
        rebuildSurfaces()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                switch RecordingDesktopKeyboardAction.resolve(keyCode: event.keyCode, hasSelection: self.state.target != nil,
                                                              isPresented: self.isPresented, isHidden: self.isTemporarilyHidden,
                                                              isMenuTracking: !self.trackingMenus.isEmpty,
                                                              isRegionDragging: self.surfaces.contains { $0.view.hasActiveGesture },
                                                              isCountingDown: self.countdown != nil) {
                case .passThrough: return false
                case .consume: return true
                case .cancel: self.cancel(); return true
                case .confirm:
                    if self.validateSelection() {
                        self.state.lock()
                        self.redraw()
                        self.onConfirm()
                    }
                    return true
                }
            }
            return consumed ? nil : event
        }
        menuObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let identifier = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSMenu.didBeginTrackingNotification { self.trackingMenus.insert(identifier) }
                    else { self.trackingMenus.remove(identifier) }
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildSurfaces() }
        }
        if !isTemporarilyHidden { NSApp.activate(ignoringOtherApps: true) }
        if !isTemporarilyHidden, let surface = surfaces.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? surfaces.first {
            surface.panel.makeKeyAndOrderFront(nil)
            surface.panel.makeFirstResponder(surface.view)
            hover(on: surface.display.id, at: localMousePoint(on: surface))
        }
    }

    func dismiss() {
        isPresented = false
        isTemporarilyHidden = false
        rebuildPending = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        trackingMenus = []
        surfaces.forEach { $0.panel.orderOut(nil); $0.panel.close() }
        surfaces = []
        countdown = nil
    }

    /// Keep the live selection and event monitors while system permission dialogs are visible.
    func setTemporarilyHidden(_ hidden: Bool) {
        isTemporarilyHidden = hidden
        if hidden {
            surfaces.forEach { $0.panel.orderOut(nil) }
            return
        }
        guard isPresented else { return }
        if rebuildPending { rebuildPending = false; rebuildSurfaces() }
        _ = refreshSelectedWindow()
        redraw()
        surfaces.forEach { $0.panel.orderFrontRegardless() }
        if let surface = surfaces.first(where: { $0.display.id == activeDisplayID }) ??
            surfaces.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? surfaces.first {
            surface.panel.makeKeyAndOrderFront(nil)
            surface.panel.makeFirstResponder(surface.view)
        }
    }

    func setMode(_ mode: RecordingSelectionMode) {
        guard self.mode != mode else {
            // Reaffirm readiness without releasing a selection when the same toolbar mode is tapped.
            onSelection(state.target)
            return
        }
        self.mode = mode
        state.reset()
        regionRect = nil
        windowFrame = nil
        publish()
        surfaces.forEach { $0.view.cancelGesture() }
        if let surface = surfaces.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) {
            activeDisplayID = surface.display.id
            hover(on: surface.display.id, at: localMousePoint(on: surface))
        }
        redraw()
    }

    /// Keyboard and assistive-technology alternative to clicking the desktop overlay.
    @discardableResult func selectWindow(_ id: UInt32) -> Bool {
        guard isPresented, !isTemporarilyHidden, countdown == nil else { return false }
        guard let hit = RecordingDesktopSelectionGeometry.liveWindow(id: id, frontToBack: windowOrder(),
                  available: inventory.windows, excludingPID: ProcessInfo.processInfo.processIdentifier) else {
            state.reset()
            windowFrame = nil
            publish()
            redraw()
            return false
        }
        mode = .window
        regionRect = nil
        windowFrame = hit.frame
        activeDisplayID = surfaces.max {
            let lhs = $0.display.frame.intersection(hit.frame)
            let rhs = $1.display.frame.intersection(hit.frame)
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        }?.display.id
        state.click(.window(id))
        publish()
        redraw()
        return true
    }

    func updateInventory(_ inventory: RecordingSourceInventory) {
        self.inventory = inventory
        if let target = state.target {
            let stillExists: Bool
            switch target {
            case let .window(id): stillExists = inventory.windows.contains { $0.id == id }
            case let .display(id), let .region(id, _): stillExists = inventory.displays.contains { $0.id == id }
            }
            if !stillExists { state.reset(); windowFrame = nil; regionRect = nil; publish() }
        }
        if isPresented {
            let screenPairs = NSScreen.screens.compactMap { screen -> (NSScreen, RecordingDisplayChoice)? in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                      let display = inventory.displays.first(where: { $0.id == id }) else { return nil }
                return (screen, display)
            }
            let layoutChanged = screenPairs.count != surfaces.count || screenPairs.contains { screen, display in
                !surfaces.contains { $0.display.id == display.id && $0.display.frame == display.frame && $0.panel.frame == screen.frame }
            }
            if layoutChanged { rebuildSurfaces() }
            else {
                _ = refreshSelectedWindow()
                redraw()
            }
        }
    }

    func setCountdown(_ value: Int?) {
        countdown = value
        if value != nil { state.lock() }
        redraw()
    }

    /// Recheck the live target immediately before either Enter or the toolbar starts recording.
    func validateSelection() -> Bool {
        guard isPresented, let target = state.target, !surfaces.contains(where: { $0.view.hasActiveGesture }) else { return false }
        if case .window = target { return refreshSelectedWindow() }
        let id: UInt32
        switch target {
        case let .display(displayID), let .region(displayID, _): id = displayID
        case .window: return false
        }
        let hardwareExists = NSScreen.screens.contains {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        let display = inventory.displays.first { $0.id == id }
        var valid = hardwareExists && display != nil
        if case let .region(_, region) = target, let display {
            valid = valid && region.isValid && CGRect(origin: .zero, size: display.frame.size)
                .contains(CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
        }
        guard valid else {
            state.reset(); regionRect = nil; windowFrame = nil; publish(); redraw()
            return false
        }
        return true
    }

    private func rebuildSurfaces() {
        // An already queued screen-change notification cannot resurrect dismissed panels.
        guard isPresented else { return }
        if isTemporarilyHidden { rebuildPending = true; return }
        surfaces.forEach { $0.panel.orderOut(nil); $0.panel.close() }
        surfaces = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = inventory.displays.first(where: { $0.id == number.uint32Value }) else { return nil }
            let panel = RecordingDesktopSelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                                       backing: .buffered, defer: false)
            panel.level = Self.overlayLevel
            panel.isOpaque = false
            // WindowServer can pass clicks through fully transparent pixels inside the selection.
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = RecordingDesktopSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onHover = { [weak self] point in self?.hover(on: display.id, at: point) }
            view.onClick = { [weak self] point in self?.click(on: display.id, at: point) }
            view.onRegion = { [weak self] rect, finished in self?.regionChanged(on: display.id, rect: rect, finished: finished) }
            panel.contentView = view
            if !isTemporarilyHidden { panel.orderFrontRegardless() }
            return Surface(screen: screen, display: display, panel: panel, view: view)
        }
        if let activeDisplayID, !surfaces.contains(where: { $0.display.id == activeDisplayID }) {
            state.reset(); self.activeDisplayID = nil; regionRect = nil; windowFrame = nil; publish()
        }
        if case let .region(displayID, region) = state.target,
           let surface = surfaces.first(where: { $0.display.id == displayID }) {
            regionRect = RecordingDesktopSelectionGeometry.overlayRect(for: region, display: surface.display, screenFrame: surface.screen.frame)
            let candidate = regionRect.flatMap { RecordingDesktopSelectionGeometry.region($0, display: surface.display, screenFrame: surface.screen.frame) }
            let wasLocked = state.locked
            state.reset()
            if wasLocked { state.selectRegion(candidate) } else { state.hover(candidate) }
            publish()
        }
        redraw()
        if NSApp.keyWindow == nil, let surface = surfaces.first(where: { $0.display.id == activeDisplayID }) ?? surfaces.first {
            surface.panel.makeKeyAndOrderFront(nil)
            surface.panel.makeFirstResponder(surface.view)
        }
    }

    private func hover(on displayID: UInt32, at point: CGPoint) {
        guard !isTemporarilyHidden, countdown == nil, trackingMenus.isEmpty else { return }
        if state.locked { _ = refreshSelectedWindow() }
        guard !state.locked, !pointerIsOverControls() else { return }
        retarget(on: displayID, at: point, locking: false)
    }

    private func retarget(on displayID: UInt32, at point: CGPoint, locking: Bool) {
        guard let surface = surfaces.first(where: { $0.display.id == displayID }) else { return }
        activeDisplayID = displayID
        let candidate: RecordingScreenTarget?
        switch mode {
        case .display: candidate = .display(displayID); windowFrame = nil
        case .window:
            let transform = CaptureDisplayTransform(captureFrame: surface.display.frame, overlayFrame: surface.screen.frame)
            let hit = RecordingDesktopSelectionGeometry.window(at: transform.captureGlobalPoint(fromOverlayLocalPoint: point),
                                                               frontToBack: windowOrder(), available: inventory.windows,
                                                               excludingPID: ProcessInfo.processInfo.processIdentifier)
            candidate = hit.map { .window($0.id) }
            windowFrame = hit?.frame
        case .region: redraw(); return
        }
        if locking { state.click(candidate) } else { state.hover(candidate) }
        publish()
        redraw()
    }

    private func click(on displayID: UInt32, at point: CGPoint) {
        guard !isTemporarilyHidden, countdown == nil, trackingMenus.isEmpty, mode != .region, !pointerIsOverControls() else { return }
        retarget(on: displayID, at: point, locking: true)
    }

    private func regionChanged(on displayID: UInt32, rect: CGRect?, finished: Bool) {
        guard !isTemporarilyHidden, countdown == nil, mode == .region,
              let surface = surfaces.first(where: { $0.display.id == displayID }) else { return }
        activeDisplayID = displayID
        regionRect = rect
        let target = rect.flatMap { RecordingDesktopSelectionGeometry.region($0, display: surface.display, screenFrame: surface.screen.frame) }
        if finished { state.selectRegion(target) } else { state.reset(); state.hover(target) }
        publish()
        redraw()
    }

    private func publish() {
        guard state.target != lastPublished else { return }
        lastPublished = state.target
        onSelection(state.target)
    }

    @discardableResult
    private func refreshSelectedWindow() -> Bool {
        guard case let .window(id) = state.target else { return true }
        let hit = RecordingDesktopSelectionGeometry.liveWindow(id: id, frontToBack: windowOrder(), available: inventory.windows,
                                                              excludingPID: ProcessInfo.processInfo.processIdentifier)
        guard let hit else {
            state.reset()
            windowFrame = nil
            publish()
            redraw()
            return false
        }
        if windowFrame != hit.frame { windowFrame = hit.frame; redraw() }
        return true
    }

    private func pointerIsOverControls() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.level.rawValue > Self.overlayLevel.rawValue &&
            !surfaces.contains(where: { $0.panel === window }) && window.frame.contains(NSEvent.mouseLocation)
        }
    }

    private func localMousePoint(on surface: Surface) -> CGPoint {
        CaptureDisplayTransform(captureFrame: surface.display.frame, overlayFrame: surface.screen.frame)
            .overlayLocalPoint(fromOverlayGlobalPoint: NSEvent.mouseLocation)
    }

    private func windowOrder() -> [RecordingDesktopWindowHit] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return RecordingDesktopWindowHit(id: id.uint32Value, frame: frame, ownerPID: owner.int32Value,
                                             layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                             alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    private func redraw() {
        for surface in surfaces {
            let active = surface.display.id == activeDisplayID
            let transform = CaptureDisplayTransform(captureFrame: surface.display.frame, overlayFrame: surface.screen.frame)
            surface.view.mode = mode
            surface.view.isActiveSurface = active
            surface.view.locked = state.locked
            surface.view.countdown = active ? countdown : nil
            surface.view.interactionEnabled = countdown == nil
            switch mode {
            case .display: surface.view.selection = active && state.target != nil ? surface.view.bounds.insetBy(dx: 2, dy: 2) : nil
            case .window:
                surface.view.selection = windowFrame.map { transform.overlayLocalRect(fromCaptureGlobalRect: $0) }
            case .region: surface.view.selection = active ? regionRect : nil
            }
            surface.view.needsDisplay = true
            surface.view.window?.invalidateCursorRects(for: surface.view)
        }
    }

    private func cancel() { dismiss(); onCancel() }
}

private final class RecordingDesktopSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RecordingDesktopSelectionView: NSView {
    var mode: RecordingSelectionMode = .display
    var selection: CGRect?
    var locked = false
    var isActiveSurface = false
    var countdown: Int?
    var interactionEnabled = true
    var onHover: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onRegion: ((CGRect?, Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private enum Gesture {
        case create(CGPoint), move(CGRect, CGPoint), resize(CGRect, CaptureResizeHandle, CGPoint)
    }
    private var gesture: Gesture?
    var hasActiveGesture: Bool { gesture != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .region ? .crosshair : .arrow)
        guard mode == .region, let selection else { return }
        addCursorRect(selection, cursor: .openHand)
        let radius = min(9, min(selection.width, selection.height) / 4)
        for handle in CaptureResizeHandle.allCases {
            let p = handle.position(in: selection)
            let cursor: NSCursor = handle == .east || handle == .west ? .resizeLeftRight :
                handle == .north || handle == .south ? .resizeUpDown : .crosshair
            addCursorRect(CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2), cursor: cursor)
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard interactionEnabled else { return }
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard mode == .region else { onClick?(point); return }
        if let selection, let handle = RecordingDesktopSelectionGeometry.handle(at: point, in: selection) {
            gesture = .resize(selection, handle, point)
        } else if let selection, selection.contains(point) {
            gesture = .move(selection, point)
        } else {
            gesture = .create(point)
            onRegion?(nil, false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionEnabled, let gesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect: CGRect
        switch gesture {
        case let .create(origin):
            rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(point.x - origin.x), height: abs(point.y - origin.y)).intersection(bounds)
        case let .move(original, origin):
            rect = CaptureInteractionGeometry.move(original, translation: CGSize(width: point.x - origin.x, height: point.y - origin.y),
                                                   within: bounds, minimumSize: RecordingDesktopSelectionGeometry.minimumRegionSize)
        case let .resize(original, handle, origin):
            rect = CaptureInteractionGeometry.resize(original, handle: handle, translation: CGSize(width: point.x - origin.x, height: point.y - origin.y),
                                                     within: bounds, minimumSize: RecordingDesktopSelectionGeometry.minimumRegionSize)
        }
        onRegion?(rect, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionEnabled, gesture != nil else { return }
        mouseDragged(with: event)
        gesture = nil
        let valid = selection.flatMap { rect in
            rect.width >= 16 && rect.height >= 16 ? rect : nil
        }
        onRegion?(valid, true)
    }

    func cancelGesture() { gesture = nil }

    override func draw(_ dirtyRect: NSRect) {
        // A subtle veil is drawn over live windows; the selected area stays transparent.
        let shade = NSBezierPath(rect: bounds)
        if let selection, !selection.intersection(bounds).isEmpty { shade.append(NSBezierPath(rect: selection)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(isActiveSurface ? 0.10 : 0.16).setFill()
        shade.fill()
        if let selection, !selection.intersection(bounds).isEmpty {
            NSColor.white.withAlphaComponent(0.90).setStroke()
            let white = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1)); white.lineWidth = 1; white.stroke()
            (locked ? NSColor.systemBlue : NSColor.white).setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = locked ? 2 : 1; border.stroke()
            if mode == .region, countdown == nil {
                for handle in CaptureResizeHandle.allCases {
                    let point = handle.position(in: selection)
                    let dot = NSBezierPath(roundedRect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5)
                    NSColor.white.setFill(); dot.fill()
                    NSColor.systemBlue.setStroke(); dot.lineWidth = 1; dot.stroke()
                }
            }
        }
        guard isActiveSurface else { return }
        if let countdown {
            let text = "\(countdown)"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 72, weight: .medium), .foregroundColor: NSColor.white]
            let circle = CGRect(x: bounds.midX - 68, y: bounds.midY - 68, width: 136, height: 136)
            NSColor.black.withAlphaComponent(0.40).setFill(); NSBezierPath(ovalIn: circle).fill()
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        let hint: String
        if locked { hint = "已选择 · Enter 开始录制 · Esc 取消" }
        else {
            switch mode {
            case .display: hint = "点按此屏幕选择 · Enter 开始录制"
            case .window: hint = "移到窗口上 · 点按选择 · Esc 取消"
            case .region: hint = "拖动框选区域 · 可移动和调整边缘"
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 15, y: 46, width: size.width + 30, height: 34)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 17, yRadius: 17).fill()
        hint.draw(at: CGPoint(x: box.minX + 15, y: box.minY + (box.height - size.height) / 2), withAttributes: attributes)
    }
}
