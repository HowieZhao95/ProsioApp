import AppKit
import ProsioCore
import Testing

@MainActor
struct OnboardingTests {
    @Test func quittingForPermissionChangesResumesButExplicitCloseStaysDismissed() {
        let defaults = isolatedDefaults()
        let progress = OnboardingProgress(defaults: defaults)
        progress.select(.capture)
        progress.handleWindowClose(isTerminating: true)
        let afterRestart = OnboardingProgress(defaults: defaults)
        #expect(afterRestart.shouldPresentOnLaunch)
        #expect(afterRestart.page == .capture)
        afterRestart.handleWindowClose(isTerminating: false)
        #expect(!OnboardingProgress(defaults: defaults).shouldPresentOnLaunch)
    }
    @Test func permissionRecheckUsesActualStatusAndDoesNotTreatAnotherGrantAsSuccess() {
        #expect(!OnboardingPermission.microphone.isGranted(statuses: [.microphone: .denied, .accessibility: .granted], screenCapture: true))
        #expect(!OnboardingPermission.screenCapture.isGranted(statuses: [.microphone: .granted], screenCapture: false))
        #expect(OnboardingPermission.accessibility.isGranted(statuses: [.accessibility: .granted], screenCapture: false))
        #expect(OnboardingPermission.screenCapture.isGranted(statuses: [:], screenCapture: true))
        #expect(!OnboardingPermission.inputMonitoring.isGranted(statuses: [.accessibility: .granted], screenCapture: true))
    }
    private func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "prosio-onboarding-tests-\(UUID().uuidString)")!
        return defaults
    }

    @Test func deferredSetupSurvivesRelaunchWithoutClaimingExperience() {
        let defaults = isolatedDefaults()
        let progress = OnboardingProgress(defaults: defaults)
        #expect(progress.shouldPresentOnLaunch)
        progress.select(.capture)
        progress.dismiss()
        let reloaded = OnboardingProgress(defaults: defaults)
        #expect(!reloaded.shouldPresentOnLaunch)
        #expect(reloaded.page == .capture)
        #expect(reloaded.experienced.isEmpty)
        reloaded.reopen()
        #expect(reloaded.page == .voice)
        #expect(!reloaded.shouldPresentOnLaunch)
    }

    @Test func sequentialNavigationAndSidebarUseSameProgress() {
        let defaults = isolatedDefaults()
        let progress = OnboardingProgress(defaults: defaults)
        #expect(progress.previous == nil)
        progress.select(.notes)
        #expect(progress.previous == .capture)
        #expect(progress.next == .tools)
        progress.markExperienced(.notes)
        progress.select(.ready)
        #expect(progress.next == nil)
        let reloaded = OnboardingProgress(defaults: defaults)
        #expect(reloaded.experienced == [.notes])
        #expect(reloaded.page == .ready)
        #expect(reloaded.shouldPresentOnLaunch)
    }

    @Test func selectedPracticeTextRoutesToOriginalTargetWithoutClipboardChange() async {
        let defaults = isolatedDefaults()
        let inserter = TextInserter(settings: AppSettings(defaults: defaults))
        let target = TestPracticeTarget(identifier: "first", selection: "一段需要改写的文字")
        inserter.practiceTarget = { target }
        let context = PracticeTextRouting.context(for: target)
        #expect(context.selectedText == "一段需要改写的文字")
        let clipboardRevision = NSPasteboard.general.changeCount
        let outcome = await inserter.insert("简短的结果", into: context)
        #expect(outcome == .accessibility)
        #expect(target.inserted == "简短的结果")
        #expect(NSPasteboard.general.changeCount == clipboardRevision)
    }

    @Test func practiceIdentityCannotMatchDifferentOrClosedEditor() {
        let first = TestPracticeTarget(identifier: "first", selection: nil)
        let second = TestPracticeTarget(identifier: "second", selection: nil)
        let context = PracticeTextRouting.context(for: first)
        #expect(!PracticeTextRouting.matches(second, context: context))
        first.practiceAvailable = false
        #expect(!PracticeTextRouting.matches(first, context: context))
        var external = context
        external.processID = -1
        #expect(!PracticeTextRouting.isPractice(external))
    }

    @Test func explicitPracticeDestinationDoesNotRequireForegroundAndRestoresNestedTarget() {
        let focus = FocusContextProvider()
        let outer = TestPracticeTarget(identifier: "outer", selection: "原文")
        let inner = TestPracticeTarget(identifier: "inner", selection: nil)
        focus.withPracticeTarget(outer) {
            #expect(PracticeTextRouting.matches(outer, context: focus.currentContext()))
            focus.withPracticeTarget(inner) {
                #expect(PracticeTextRouting.matches(inner, context: focus.currentContext()))
            }
            #expect(PracticeTextRouting.matches(outer, context: focus.currentContext()))
        }
    }

    @Test func realPracticeEditorReplacesCapturedSelectionAndProtectsNewEdits() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = OnboardingPracticeTextView(frame: window.contentView!.bounds)
        window.contentView = text
        text.string = "Hello world"
        text.setSelectedRange(NSRange(location: 6, length: 5))
        let context = PracticeTextRouting.context(for: text)
        #expect(context.selectedText == "world")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(text.insertPracticeText("Prosio"))
        #expect(text.string == "Hello Prosio")
        text.preparePracticeInsertion()
        text.string = "A newer edit"
        #expect(!text.insertPracticeText("Late result"))
        #expect(text.string == "A newer edit")
    }
}

@MainActor
private final class TestPracticeTarget: PracticeTextTarget {
    let practiceIdentifier: String
    var practiceSelectedText: String?
    var practiceAvailable = true
    var inserted: String?
    init(identifier: String, selection: String?) { practiceIdentifier = identifier; practiceSelectedText = selection }
    func preparePracticeInsertion() {}
    func insertPracticeText(_ text: String) -> Bool { inserted = text; return true }
}
