import AVFoundation
import Foundation

@MainActor
final class RecordingProjectExporter {
    func export(session: RecordingSessionManifest, sourceDirectory: URL, destination: URL, editor: RecordingEditor) async throws -> URL {
        try RecordingExportSupport.validate(session)
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else { throw RecordingExportError.destinationExists }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".prosio-handoff-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("Media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var media: [RecordingMediaInfo] = []
        var packaged = session
        for (index, segment) in session.segments.enumerated() {
            try Task.checkCancellation()
            guard let source = session.sources.first(where: { $0.id == segment.sourceID }) else { throw RecordingExportError.invalidManifest("素材来源缺失") }
            let info = try await RecordingExportSupport.inspectedMedia(segment, source: source, directory: sourceDirectory)
            let fileName = segment.id.uuidString + "." + (info.url.pathExtension.isEmpty ? "mov" : info.url.pathExtension)
            let path = "Media/" + fileName
            try await RecordingExportSupport.copyMedia(from: info.url, to: temporary.appendingPathComponent(path))
            packaged.segments[index].relativePath = path
            media.append(RecordingMediaInfo(segment: packaged.segments[index], source: source, url: destination.appendingPathComponent(path), duration: info.duration, width: info.width, height: info.height, frameDuration: info.frameDuration, sampleRate: info.sampleRate, channels: info.channels))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(packaged).write(to: temporary.appendingPathComponent("recording.json"), options: .atomic)
        let fileName = editor == .jianying ? "draft_content.json" : "Timeline." + editor.fileExtension
        switch editor {
        case .finalCutPro:
            try Self.fcpxml(session: packaged, media: media).write(to: temporary.appendingPathComponent(fileName), options: .atomic)
        case .resolve, .premiere:
            try Self.fcp7XML(session: packaged, media: media).write(to: temporary.appendingPathComponent(fileName), options: .atomic)
        case .jianying:
            try RecordingJianyingAdapter.write(session: packaged, media: media, directory: temporary, finalDirectory: destination)
        }
        let note = """
        Prosio 录制交接 — \(editor.title)

        \(editor.importVerificationNote)

        原片位于 Media，recording.json 保留整数微秒对齐信息；请整体保留此文件夹。
        当前交接文件使用本次导出位置的文件 URL。移动文件夹后，编辑软件可能要求重新链接 Media；也可在 Prosio 重新导出到新位置。不要单独移动 XML/草稿或删除原片。
        Final Cut Pro：导入 Timeline.fcpxml，时间线中为原生多机位，麦克风和系统声音各自独立。
        Resolve / Premiere：导入 Timeline.xml，得到独立对齐轨道；在编辑软件中创建多机位。FCP7 XML 以时间线帧率取最近帧，微秒原始偏移保存在 recording.json。
        剪映：实验性本地明文草稿。将整个包作为新草稿处理，按软件要求重新链接素材。未验证 macOS 版本，不自动写入或覆盖剪映草稿目录，不保证受加密格式限制的版本可读取。
        """
        try Data(note.utf8).write(to: temporary.appendingPathComponent("导入说明.txt"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination.appendingPathComponent(fileName)
    }

    static func fcpxml(session: RecordingSessionManifest, media: [RecordingMediaInfo]) -> Data {
        let root = element("fcpxml", ["version": "1.10"])
        let resources = element("resources")
        root.addChild(resources)
        let video = media.filter(\.isVideo)
        for (index, item) in video.enumerated() {
            resources.addChild(element("format", ["id": "f\(index)", "frameDuration": rational(item.frameDuration ?? CMTime(value: 1, timescale: 30)), "width": "\(item.width ?? 1920)", "height": "\(item.height ?? 1080)", "colorSpace": "1-1-1"]))
        }
        let primaryFormat = video.isEmpty ? "fallback" : "f0"
        if video.isEmpty { resources.addChild(element("format", ["id": "fallback", "frameDuration": "1/30s", "width": "1920", "height": "1080"])) }
        for (index, item) in media.enumerated() {
            var attributes = ["id": "r\(index)", "name": item.source.name, "start": "0s", "duration": rational(item.duration), "hasVideo": item.isVideo ? "1" : "0", "hasAudio": item.isVideo ? "0" : "1"]
            if item.isVideo { attributes["format"] = "f\(video.firstIndex(where: { $0.segment.id == item.segment.id }) ?? 0)" }
            else {
                attributes["audioSources"] = "1"
                attributes["audioChannels"] = "\(item.channels ?? 1)"
                attributes["audioRate"] = "\(item.sampleRate ?? 48000)"
            }
            let asset = element("asset", attributes)
            asset.addChild(element("media-rep", ["kind": "original-media", "src": item.url.absoluteString]))
            resources.addChild(asset)
        }
        let multicamMedia = element("media", ["id": "multicam", "name": session.title])
        let multicam = element("multicam", ["format": primaryFormat, "tcStart": "0s", "tcFormat": "NDF"])
        multicamMedia.addChild(multicam)
        let angles = session.sources.filter { $0.kind == .screen || $0.kind == .camera }.filter { source in video.contains { $0.source.id == source.id } }
        for (angleIndex, source) in angles.enumerated() {
            let angle = element("mc-angle", ["angleID": "angle\(angleIndex)", "name": source.name])
            var end: Int64 = 0
            for (index, item) in media.enumerated().filter({ $0.element.source.id == source.id }).sorted(by: { $0.element.segment.timelineStartMicroseconds < $1.element.segment.timelineStartMicroseconds }) {
                if item.segment.timelineStartMicroseconds > end {
                    angle.addChild(element("gap", ["name": "来源间隙", "offset": micros(end), "start": "0s", "duration": micros(item.segment.timelineStartMicroseconds - end)]))
                }
                angle.addChild(assetClip(item, index: index))
                end = item.segment.timelineEndMicroseconds ?? end
            }
            if end < session.durationMicroseconds { angle.addChild(element("gap", ["name": "来源间隙", "offset": micros(end), "start": "0s", "duration": micros(session.durationMicroseconds - end)])) }
            multicam.addChild(angle)
        }
        resources.addChild(multicamMedia)
        let library = element("library")
        let event = element("event", ["name": session.title])
        let project = element("project", ["name": session.title])
        let sequence = element("sequence", ["format": primaryFormat, "duration": micros(session.durationMicroseconds), "tcStart": "0s", "tcFormat": "NDF", "audioLayout": "stereo", "audioRate": "48k"])
        let spine = element("spine")
        let main = angles.isEmpty ? element("gap", ["offset": "0s", "start": "0s", "duration": micros(session.durationMicroseconds)]) : element("mc-clip", ["ref": "multicam", "name": session.title, "offset": "0s", "start": "0s", "duration": micros(session.durationMicroseconds)])
        if !angles.isEmpty { main.addChild(element("mc-source", ["angleID": "angle0", "srcEnable": "video"])) }
        var laneBySource: [String: Int] = [:]
        for source in session.sources where source.kind == .microphone || source.kind == .systemAudio { laneBySource[source.id] = -(laneBySource.count + 1) }
        for (index, item) in media.enumerated() where !item.isVideo {
            let clip = assetClip(item, index: index, lane: laneBySource[item.source.id] ?? -1)
            main.addChild(clip)
        }
        spine.addChild(main)
        sequence.addChild(spine); project.addChild(sequence); event.addChild(project); library.addChild(event); root.addChild(library)
        return document(root, doctype: "fcpxml")
    }

    private static func assetClip(_ item: RecordingMediaInfo, index: Int, lane: Int? = nil) -> XMLElement {
        var attributes = ["name": item.source.name, "ref": "r\(index)", "offset": micros(item.segment.timelineStartMicroseconds), "start": micros(item.segment.mediaStartMicroseconds), "duration": micros(item.segment.durationMicroseconds), "srcEnable": item.isVideo ? "video" : "audio"]
        if let lane { attributes["lane"] = "\(lane)"; attributes["audioRole"] = item.source.kind == .microphone ? "dialogue" : "effects" }
        return element("asset-clip", attributes)
    }

    static func fcp7XML(session: RecordingSessionManifest, media: [RecordingMediaInfo]) -> Data {
        let frameDuration = media.first(where: \.isVideo)?.frameDuration ?? CMTime(value: 1, timescale: 30)
        let fps = 1 / frameDuration.seconds
        let ntsc = abs(fps - 29.97002997) < 0.01 || abs(fps - 59.94005994) < 0.01 || abs(fps - 23.976023976) < 0.01
        let base = Int(fps.rounded())
        let timelineFPS = Double(base) * (ntsc ? 1000.0 / 1001 : 1)
        func frames(_ value: Int64) -> String { String(Int64((Double(value) * timelineFPS / 1_000_000).rounded())) }
        func rate() -> XMLElement {
            let node = element("rate"); node.addChild(textElement("timebase", "\(base)")); node.addChild(textElement("ntsc", ntsc ? "TRUE" : "FALSE")); return node
        }
        let root = element("xmeml", ["version": "5"])
        let sequence = element("sequence", ["id": "sequence-\(session.id)"])
        sequence.addChild(textElement("name", session.title)); sequence.addChild(textElement("duration", frames(session.durationMicroseconds))); sequence.addChild(rate())
        let mediaNode = element("media")
        for isVideo in [true, false] {
            let kind = isVideo ? "video" : "audio"
            let section = element(kind)
            if isVideo, let primary = media.first(where: \.isVideo) {
                let format = element("format"); let sample = element("samplecharacteristics")
                sample.addChild(rate()); sample.addChild(textElement("width", "\(primary.width ?? 1920)")); sample.addChild(textElement("height", "\(primary.height ?? 1080)")); sample.addChild(textElement("pixelaspectratio", "square")); sample.addChild(textElement("fielddominance", "none")); format.addChild(sample); section.addChild(format)
            } else if !isVideo {
                section.addChild(textElement("channelcount", "2"))
                let outputs = element("outputs"); let group = element("group")
                group.addChild(textElement("index", "1")); group.addChild(textElement("numchannels", "2")); group.addChild(textElement("downmix", "0"))
                for channel in 1...2 { let node = element("channel"); node.addChild(textElement("index", "\(channel)")); group.addChild(node) }
                outputs.addChild(group); section.addChild(outputs)
            }
            var audioTrackBase = 0
            for source in session.sources where (source.kind == .screen || source.kind == .camera) == isVideo {
                let items = media.enumerated().filter { $0.element.source.id == source.id }.sorted { $0.element.segment.timelineStartMicroseconds < $1.element.segment.timelineStartMicroseconds }
                guard !items.isEmpty else { continue }
                let channelCount = isVideo ? 1 : max(1, items.map { $0.element.channels ?? 1 }.max() ?? 1)
                for channel in 1...channelCount {
                let track = element("track")
                for (clipPosition, entry) in items.enumerated() {
                    let (index, item) = entry
                    if !isVideo && channel > (item.channels ?? 1) { continue }
                    let clip = element("clipitem", ["id": isVideo ? "clip-\(index)" : "clip-\(index)-c\(channel)"])
                    for (name, value) in [("name", source.name), ("duration", frames(Int64(item.duration.seconds * 1_000_000))), ("start", frames(item.segment.timelineStartMicroseconds)), ("end", frames(item.segment.timelineStartMicroseconds + item.segment.durationMicroseconds)), ("in", frames(item.segment.mediaStartMicroseconds)), ("out", frames(item.segment.mediaStartMicroseconds + item.segment.durationMicroseconds))] { clip.addChild(textElement(name, value)) }
                    clip.addChild(rate())
                    let file = element("file", ["id": "file-\(index)"])
                    if channel == 1 {
                    file.addChild(textElement("name", item.url.lastPathComponent)); file.addChild(textElement("pathurl", item.url.absoluteString)); file.addChild(rate()); file.addChild(textElement("duration", frames(Int64(item.duration.seconds * 1_000_000))))
                    let fileMedia = element("media"); let fileSection = element(kind); let sample = element("samplecharacteristics")
                    if isVideo { sample.addChild(rate()); sample.addChild(textElement("width", "\(item.width ?? 1920)")); sample.addChild(textElement("height", "\(item.height ?? 1080)")); sample.addChild(textElement("pixelaspectratio", "square")); sample.addChild(textElement("fielddominance", "none")) }
                    else { sample.addChild(textElement("depth", "16")); sample.addChild(textElement("samplerate", "\(item.sampleRate ?? 48000)")); fileSection.addChild(textElement("channelcount", "\(item.channels ?? 1)")) }
                    fileSection.addChild(sample); fileMedia.addChild(fileSection); file.addChild(fileMedia)
                    }
                    clip.addChild(file)
                    let sourceTrack = element("sourcetrack"); sourceTrack.addChild(textElement("mediatype", kind)); if !isVideo { sourceTrack.addChild(textElement("trackindex", "\(channel)")) }; clip.addChild(sourceTrack)
                    if !isVideo && (item.channels ?? 1) > 1 {
                        for linkedChannel in 1...(item.channels ?? 1) {
                            let link = element("link")
                            link.addChild(textElement("linkclipref", "clip-\(index)-c\(linkedChannel)"))
                            link.addChild(textElement("mediatype", "audio"))
                            link.addChild(textElement("trackindex", "\(audioTrackBase + linkedChannel)"))
                            link.addChild(textElement("clipindex", "\(clipPosition + 1)"))
                            link.addChild(textElement("groupindex", "1"))
                            clip.addChild(link)
                        }
                    }
                    track.addChild(clip)
                }
                track.addChild(textElement("enabled", "TRUE")); track.addChild(textElement("locked", "FALSE"))
                if !isVideo && channelCount == 2 { track.addChild(textElement("outputchannelindex", "\(channel)")) }
                section.addChild(track)
                }
                if !isVideo { audioTrackBase += channelCount }
            }
            mediaNode.addChild(section)
        }
        sequence.addChild(mediaNode); root.addChild(sequence)
        return document(root, doctype: "xmeml")
    }

    static func micros(_ value: Int64) -> String { rational(CMTime(value: value, timescale: 1_000_000)) }
    static func rational(_ time: CMTime) -> String {
        if time.value == 0 { return "0s" }
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? abs(a) : gcd(b, a % b) }
        let divisor = gcd(time.value, Int64(time.timescale))
        return "\(time.value / divisor)/\(Int64(time.timescale) / divisor)s"
    }
    private static func element(_ name: String, _ attributes: [String: String] = [:]) -> XMLElement {
        let node = XMLElement(name: name)
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) { node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
        return node
    }
    private static func textElement(_ name: String, _ value: String) -> XMLElement { XMLElement(name: name, stringValue: value) }
    private static func document(_ root: XMLElement, doctype: String) -> Data {
        let xml = XMLDocument(rootElement: root); xml.characterEncoding = "UTF-8"; xml.version = "1.0"
        let dtd = XMLDTD(); dtd.name = doctype; xml.dtd = dtd
        return xml.xmlData(options: [.nodePrettyPrint])
    }
}
