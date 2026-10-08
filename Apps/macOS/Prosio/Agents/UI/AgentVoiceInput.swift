import Foundation
import Observation

nonisolated struct AgentVoiceTarget: Sendable, Equatable {
    var taskID: String
    var taskTitle: String
    var turnID: String
    var decision: AgentDecision?

    var vocabulary: [String] {
        var words = [taskTitle] + (decision?.options.map(\.label) ?? [])
        if let options = decision?.options {
            words += options.map { "选择\($0.label)" }
        }
        var seen: Set<String> = []
        return words.filter { !$0.isEmpty && $0.count <= 80 && seen.insert($0).inserted }.prefix(24).map { $0 }
    }
}

@MainActor struct AgentVoiceStream {
    var text: AsyncThrowingStream<String, Error>
    var stop: () -> Void
    var cancel: () -> Void
}

/// Captures a stable task/question destination before permission or transcription awaits.
@Observable @MainActor final class AgentVoiceInput {
    private(set) var target: AgentVoiceTarget?
    private(set) var text = ""
    private(set) var recording = false
    private(set) var finishing = false
    private(set) var message: String?
    @ObservationIgnored var factory: ((AgentVoiceTarget) async throws -> AgentVoiceStream)?
    @ObservationIgnored var onDraft: ((AgentVoiceTarget, String) -> Void)?
    @ObservationIgnored private var stream: AgentVoiceStream?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    var preparing: Bool { recording && stream == nil }

    func rejectDraft() { message = "原任务或问题已更新，语音文字未写入回答；请检查后重新处理。" }

    func start(target: AgentVoiceTarget) {
        guard !recording, !finishing else { return }
        guard let factory else { message = "语音输入尚未连接，请先使用文字回答。"; return }
        revision += 1
        let current = revision
        self.target = target; text = ""; message = nil; recording = true
        consumer = Task { [weak self] in
            do {
                let stream = try await factory(target)
                guard let self, self.revision == current, !Task.isCancelled else { stream.cancel(); return }
                self.stream = stream
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    self?.finish()
                }
                for try await text in stream.text {
                    guard self.revision == current, !Task.isCancelled else { return }
                    self.text = text
                }
                self.complete(current: current)
            } catch {
                guard let self, self.revision == current else { return }
                self.message = "语音识别未完成，请检查识别文字或改用输入。"
                self.complete(current: current)
            }
        }
    }

    func finish() {
        guard recording, let stream else { return }
        recording = false; finishing = true; stream.stop(); timeout?.cancel()
        let current = revision
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.revision == current else { return }
            self.message = "识别结果尚未完整，请检查文字后再发送。"
            self.complete(current: current)
            self.consumer?.cancel()
        }
    }

    func cancel() {
        revision += 1; consumer?.cancel(); timeout?.cancel(); stream?.cancel(); stream = nil
        recording = false; finishing = false; target = nil; text = ""; message = nil
    }

    private func complete(current: Int) {
        guard revision == current else { return }
        revision += 1
        timeout?.cancel(); stream?.cancel(); stream = nil
        recording = false; finishing = false
        if let target, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onDraft?(target, text) }
        else if message == nil { message = "没有识别到文字，请重试。" }
    }
}
