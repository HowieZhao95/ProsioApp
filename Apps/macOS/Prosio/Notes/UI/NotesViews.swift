import AppKit
import QuartzCore
import SwiftUI

struct DailyNotesView: View {
    @Bindable var notes: DailyNotesCoordinator
    @State private var calendarVisible = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { notes.hide() } label: { Image(systemName: "xmark").frame(width: 22, height: 24) }
                    .help("隐藏便签（⌘W）")
                Button { calendarVisible.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(dateTitle).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                    }.frame(height: 24)
                }
                Spacer(minLength: 2)
                Button {
                    calendarVisible = false
                    notes.select(notes.today)
                } label: {
                    Text("今天 \(notes.todayRemaining) 项待办")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.045), in: Capsule())
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .help("回到今天的笔记")
                .accessibilityLabel("今天还有 \(notes.todayRemaining) 项任务未完成，点击回到今天的笔记")
                if notes.selectedDay != notes.today {
                    Button { notes.select(notes.today) } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 24)
                    }.help("回到今天").accessibilityLabel("回到今天")
                }
                Button { notes.pinned.toggle() } label: {
                    Image(systemName: notes.pinned ? "pin.fill" : "pin")
                        .frame(width: 22, height: 24)
                        .foregroundStyle(notes.pinned ? Color.accentColor : Color.secondary)
                }.help(notes.pinned ? "取消置顶" : "置顶显示").accessibilityLabel(notes.pinned ? "已置顶" : "置顶")

            }
            .buttonStyle(.plain).font(.system(size: 11))
            .padding(.horizontal, 10).frame(height: 34).disabled(notes.busy)
            .popover(isPresented: $calendarVisible, arrowEdge: .bottom) {
                NotesCalendarView(notes: notes) { day in notes.select(day) }
            }
            Divider()
            if let reason = notes.recoveryError ?? notes.message ?? notes.unsupported {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if notes.conflict {
                            Button("查看磁盘版本") { notes.editor.previewDisk() }
                            Button("采用磁盘版本…") { notes.useDiskVersion() }
                        }
                        if !notes.conflict && (notes.message != nil || notes.recoveryError != nil) {
                            Button("重试") { notes.retry() }
                        }
                    }.font(.system(size: 12)).buttonStyle(.link)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.4))
            }
            NoteEditorView(bridge: notes.editor).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 320, minHeight: 240)
        .ignoresSafeArea(.container, edges: .top)
    }
    private var dateTitle: String {
        notes.selectedDay.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()) + (notes.selectedDay == notes.today ? " · 今天" : "")
    }
}

struct NotesCalendarView: View {
    let notes: DailyNotesCoordinator
    let select: (NoteDay) -> Void
    @State private var month: Date
    private let calendar = Calendar(identifier: .gregorian)
    init(notes: DailyNotesCoordinator, select: @escaping (NoteDay) -> Void) {
        self.notes = notes; self.select = select
        _month = State(initialValue: Calendar(identifier: .gregorian).date(from: Calendar(identifier: .gregorian).dateComponents([.year, .month], from: notes.selectedDay.date))!)
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(month.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month())).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24) }.help("上个月")
                Button { month = calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24) }
                    .disabled(calendar.isDate(month, equalTo: notes.today.date, toGranularity: .month)).help("下个月")
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(height: 18) }
                ForEach((0..<offset).map { "padding-\($0)" }, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(1...calendar.range(of: .day, in: .month, for: month)!.count, id: \.self) { number in
                    let date = calendar.date(byAdding: .day, value: number - 1, to: month)!
                    let day = NoteDay(date)
                    let selected = day == notes.selectedDay
                    let summary = notes.summary(for: day)
                    let holidays = notes.holidays.names[day] ?? []
                    let holidayLabel = holidays.isEmpty ? "" : "，" + holidays.joined(separator: "、")
                    let contentLabel = notes.notedDays.contains(day) ? "，有便签" : "，空白"
                    let dayLabel = "\(day.key)\(holidayLabel)，已完成 \(summary.completed) 项，未完成 \(summary.remaining) 项\(contentLabel)"
                    Button { select(day) } label: {
                        VStack(spacing: 4) {
                            Text("\(number)").font(.system(size: 13, weight: selected ? .semibold : .regular)).monospacedDigit()
                            if let holiday = holidays.first {
                                Text(holiday).font(.system(size: 8)).lineLimit(1)
                                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            }
                            if !summary.tasks.isEmpty {
                                Text("✓\(summary.completed) · ○\(summary.remaining)")
                                    .font(.system(size: 9)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).opacity(selected ? 0.9 : 0.55)
                            } else {
                                Circle().fill(notes.notedDays.contains(day) ? (selected ? Color.accentColor : Color.secondary) : Color.clear).frame(width: 4, height: 4)
                            }
                        }.frame(maxWidth: .infinity).frame(height: notes.holidays.names.isEmpty ? 40 : 52)
                            .foregroundStyle(selected || day == notes.today ? Color.accentColor : Color.primary)
                            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(day == notes.today && !selected ? Color.accentColor.opacity(0.4) : .clear))
                    }.buttonStyle(.plain).disabled(day > notes.today || notes.busy)
                        .help(holidays.joined(separator: "、"))
                        .accessibilityLabel(dayLabel)
                }
            }
            Divider()
            HStack {
                Text("✓ 完成   ○ 待办").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("回到今天") { select(notes.today) }.font(.system(size: 12)).buttonStyle(.link)
            }
            taskPreview
        }.padding(18).frame(width: 348)
            .task(id: month) { notes.holidays.refresh(month: month) }

    }
    private var taskPreview: some View {
        let summary = notes.summary(for: notes.selectedDay)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(notes.selectedDay.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()) + "的任务")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("已完成 \(summary.completed) · 未完成 \(summary.remaining)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let holidays = notes.holidays.names[notes.selectedDay], !holidays.isEmpty {
                Text(holidays.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.tasks.isEmpty {
                Text("当天暂无任务").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summary.tasks) { task in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13)).frame(width: 16).padding(.top, 2)
                                    .foregroundStyle(task.completed ? Color.secondary : Color.accentColor)
                                Text((try? AttributedString(markdown: task.title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(task.title))
                                    .strikethrough(task.completed).foregroundStyle(task.completed ? Color.secondary : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 13)).lineSpacing(3).padding(.vertical, 6)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel((task.completed ? "已完成：" : "未完成：") + task.title)
                        }
                    }.padding(.vertical, 1)
                }.frame(height: min(CGFloat(summary.tasks.count) * 34, 170))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var offset: Int { (calendar.component(.weekday, from: month) + 5) % 7 }
}

struct NotesSettingsView: View {
    @Bindable var notes: DailyNotesCoordinator
    var body: some View {
        Form {
            Section("存储位置") {
                HStack {
                    Text(notes.directory?.path ?? "尚未选择存储文件夹").font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择文件夹…") { notes.chooseDirectory() }.disabled(notes.busy)
                }
                Text("每天自动保存为 YYYY-MM-DD.md。空白日期不会创建文件；未设置目录时，各天草稿分别保留。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("更换目录可迁移或仅切换；原文件保留，同日期冲突不会覆盖。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let error = notes.migrationError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            }
            Section("系统节假日") {
                Toggle("显示系统日历的节假日", isOn: Binding(get: { notes.holidays.enabled }, set: { notes.holidays.setEnabled($0) }))
                    .disabled(notes.holidays.requesting)
                if notes.holidays.enabled {
                    if !notes.holidays.choices.isEmpty {
                        Picker("节假日日历", selection: Binding(get: { notes.holidays.calendarID }, set: { notes.holidays.calendarID = $0 })) {
                            Text("自动识别节假日日历").tag("")
                            ForEach(notes.holidays.choices) { choice in Text(choice.title).tag(choice.id) }
                        }
                    }
                    Button(notes.holidays.requesting ? "正在连接…" : "连接系统日历") { notes.holidays.setEnabled(true) }
                        .disabled(notes.holidays.requesting)
                }
                Text(notes.holidays.status).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("仅读取所选日历中的全天事件，不修改系统日历。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("书写与窗口") {
                Picker("外观", selection: $notes.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Picker("正文大小", selection: $notes.fontSize) { ForEach([14, 16, 18], id: \.self) { Text("\($0) pt").tag($0) } }
                Toggle("置顶显示", isOn: $notes.pinned)
                Picker("唤出快捷键", selection: Binding(get: { notes.shortcut.selection }, set: { notes.shortcut.selection = $0 })) {
                    ForEach(NotesHotkey.Shortcut.allCases) { Text($0.label).tag($0) }
                }
                if let conflict = notes.shortcut.conflict { Text(conflict).font(.system(size: 12)).foregroundStyle(.red) }
            }
            Button("打开每日便签") { notes.show() }
        }.formStyle(.grouped)
    }
}

@MainActor final class NotesPanel: NSPanel, NSWindowDelegate {
    private weak var notes: DailyNotesCoordinator?
    private var transitionID = UUID()
    private var requestedVisible = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(coordinator: DailyNotesCoordinator) {
        notes = coordinator
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        super.init(contentRect: NSRect(x: visible.maxX - 444, y: visible.maxY - 534, width: 420, height: 510),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Prosio 每日便签"; titleVisibility = .hidden; titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        level = coordinator.pinned ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isReleasedWhenClosed = false; isMovableByWindowBackground = true
        minSize = NSSize(width: 320, height: 240)
        contentView = NSHostingView(rootView: DailyNotesView(notes: coordinator))
        delegate = self
        setFrameAutosaveName("ProsioDailyNotes")
        _ = setFrameUsingName("ProsioDailyNotes")
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.maxY - frame.height - 24))
        }
    }
    func presentAnimated() {
        transitionID = UUID(); requestedVisible = true
        if !isVisible { alphaValue = 0 }
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }
    func dismissAnimated() {
        transitionID = UUID(); requestedVisible = false
        let ticket = transitionID
        guard isVisible else { alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.transitionID == ticket, !self.requestedVisible else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { notes?.hide(); return false }
    func windowDidMove(_ notification: Notification) { saveFrame(usingName: "ProsioDailyNotes") }
    func windowDidResize(_ notification: Notification) { saveFrame(usingName: "ProsioDailyNotes") }
}
