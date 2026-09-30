import AppKit
import SwiftUI

enum MenuBarPane: Hashable, CaseIterable {
    case voice, capture, meeting

    var title: String {
        switch self {
        case .voice: "语音输入"
        case .capture: "屏幕截图"
        case .meeting: "会议转写"
        }
    }
}

/// Shared native menu structure. Its content is injected so previews can render without
/// constructing AppEnvironment or starting any system service.
struct MenuBarShell<Content: View, Footer: View>: View {
    @Binding var selectedPane: MenuBarPane
    @ViewBuilder var content: (MenuBarPane) -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Prosio").font(.system(size: 15, weight: .semibold))
                    Text("语音与屏幕，随手可用")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 14)

            HStack(spacing: 2) {
                ForEach(MenuBarPane.allCases, id: \.self) { pane in
                    let selected = selectedPane == pane
                    Button { selectedPane = pane } label: {
                        Text(pane.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(selected ? Color.primary.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pane.title)
                    .accessibilityValue(selected ? "已选中" : "未选中")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .frame(width: 320)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            ScrollView {
                content(selectedPane)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)

            Divider()
            footer()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 352)
        .frame(maxHeight: min(560, (NSScreen.main?.visibleFrame.height ?? 560) - 40))
        .background(.regularMaterial)
    }
}

struct MenuBarFeatureCard: View {
    let title: String
    let detail: String
    var active = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 75, alignment: .leading)
        .padding(14)
        .background(active ? Color.red.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Color.red.opacity(0.22) : Color.primary.opacity(0.08)))
    }
}

struct MenuBarVoiceBusyBanner: View {
    var isListening: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isListening ? "waveform" : "ellipsis.circle.fill")
                .foregroundStyle(.red)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(isListening ? "语音输入进行中" : "语音任务进行中")
                    .font(.system(size: 12, weight: .semibold))
                Text(isListening ? "结束语音后可截图" : "语音处理完成后可截图")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.18)))
    }
}
