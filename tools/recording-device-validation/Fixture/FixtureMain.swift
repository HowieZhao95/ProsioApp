import AppKit
import AVFoundation
import CoreMedia
import Darwin
import SwiftUI

@main struct RecordingValidationFixtureMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = FixtureDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var expectedParentPID: Int32 = 0
    private var controlURL: URL?
    private var signalURL: URL?
    private var timer: Timer?
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var lastPulseUptime = -Double.infinity
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let index = CommandLine.arguments.firstIndex(of: "--handshake"),
              CommandLine.arguments.indices.contains(index + 1) else { NSApp.terminate(nil); return }
        guard let parentIndex = CommandLine.arguments.firstIndex(of: "--parent-pid"),
              CommandLine.arguments.indices.contains(parentIndex + 1),
              let parentPID = Int32(CommandLine.arguments[parentIndex + 1]),
              ValidationFixtureOwner.parentIsPresent(expectedParentPID: parentPID, currentParentPID: getppid()) else {
            NSApp.terminate(nil); return
        }
        expectedParentPID = parentPID
        let target = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        controlURL = target.deletingLastPathComponent().appendingPathComponent("fixture-control.json")
        signalURL = target.deletingLastPathComponent().appendingPathComponent("fixture-signal-events.jsonl")
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(checkToneControl), userInfo: nil, repeats: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Prosio · 动态验收画面"
        window.contentView = NSHostingView(rootView: FixturePattern())
        window.delegate = self
        window.center()
        window.orderFrontRegardless()
        self.window = window
        let handshake = ValidationFixtureHandshake(processID: ProcessInfo.processInfo.processIdentifier,
            windowID: UInt32(window.windowNumber), bundleID: Bundle.main.bundleIdentifier ?? "",
            createdAt: .now, hostTimeMicroseconds: CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000, method: .roundHalfAwayFromZero).value)
        do { try JSONEncoder().encode(handshake).write(to: target, options: .atomic) }
        catch { NSApp.terminate(nil) }
    }
    @objc private func checkToneControl() {
        guard ValidationFixtureOwner.parentIsPresent(expectedParentPID: expectedParentPID, currentParentPID: getppid()) else {
            player?.stop()
            audioEngine?.stop()
            NSApp.terminate(nil)
            return
        }
        guard let controlURL, let data = try? Data(contentsOf: controlURL),
              let control = try? JSONDecoder().decode(ValidationFixtureControl.self, from: data),
              control.testToneEnabled, ProcessInfo.processInfo.systemUptime - lastPulseUptime >= 5 else { return }
        do {
            if audioEngine == nil {
                let engine = AVAudioEngine()
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
                node.volume = 0.15
                try engine.start()
                node.play()
                audioEngine = engine
                player = node
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800),
                  let channel = buffer.floatChannelData?[0], let player else { return }
            buffer.frameLength = 4800
            for sample in 0..<4800 {
                let envelope = min(1, Double(sample) / 240, Double(4799 - sample) / 240)
                channel[sample] = Float(sin(2 * .pi * 440 * Double(sample) / 48_000) * 0.2 * envelope)
            }
            player.scheduleBuffer(buffer)
            lastPulseUptime = ProcessInfo.processInfo.systemUptime
            if let signalURL {
                let event = ValidationSignalEvent(date: .now,
                    hostTimeMicroseconds: CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000, method: .roundHalfAwayFromZero).value,
                    kind: "scheduledTestPulse", frequencyHz: 440, scheduledFrames: 4800)
                var bytes = try JSONEncoder().encode(event)
                bytes.append(0x0a)
                if !FileManager.default.fileExists(atPath: signalURL.path) { FileManager.default.createFile(atPath: signalURL.path, contents: nil) }
                let file = try FileHandle(forWritingTo: signalURL)
                try file.seekToEnd()
                try file.write(contentsOf: bytes)
                try file.close()
            }
        } catch { /* Playback never blocks fixture animation or implies successful captured sound. */ }
    }
    func windowWillClose(_ notification: Notification) { audioEngine?.stop(); NSApp.terminate(nil) }
}

@MainActor private struct FixturePattern: View {
    private let originUptime = ProcessInfo.processInfo.systemUptime
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let elapsed = ProcessInfo.processInfo.systemUptime - originUptime
            GeometryReader { geometry in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    VStack(spacing: 22) {
                        Text("动态录屏验收").font(.title2.weight(.medium))
                        Text(String(format: "%09.3f", elapsed)).font(.system(size: 68, weight: .light, design: .monospaced)).monospacedDigit()
                        Text(context.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            ForEach(0..<8) { index in
                                Color(hue: Double(index) / 8, saturation: 0.65, brightness: 0.85)
                            }
                        }.frame(height: 24).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("可关闭测试屏幕失联隔离；原窗口关闭后不会换录其他窗口")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(40)
                    Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                        .position(x: 24 + (geometry.size.width - 48) * (sin(elapsed * 2) + 1) / 2,
                                  y: geometry.size.height - 28)
                }
            }
        }
    }
}
