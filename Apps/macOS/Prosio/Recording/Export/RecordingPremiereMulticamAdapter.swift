import Foundation

// Apple documents XMEML multiclip / angle / clip and clipitem's nested sequence.
// Adobe's CS6 reference documents uncollapsed <= 4 input multiclip import.
// Current Premiere behavior, especially nested segmented angles, needs app acceptance.
@MainActor
enum RecordingPremiereMulticamAdapter {
    static func candidate(session: RecordingSessionManifest, media: [RecordingMediaInfo]) throws -> Data {
        let document = try XMLDocument(data: RecordingProjectExporter.fcp7XML(session: session, media: media), options: [.nodeLoadExternalEntitiesNever])
        guard let sequence = try document.nodes(forXPath: "/xmeml/sequence").first as? XMLElement,
              let video = try sequence.nodes(forXPath: "media/video").first as? XMLElement,
              let rate = try sequence.nodes(forXPath: "rate").first as? XMLElement,
              let duration = try sequence.nodes(forXPath: "duration").first?.stringValue else { throw RecordingExportError.invalidManifest("多机位时间线缺失") }
        let tracks = try video.nodes(forXPath: "track").compactMap { $0 as? XMLElement }
        let sources = session.sources.filter { source in (source.kind == .screen || source.kind == .camera) && media.contains { $0.source.id == source.id } }
        guard !tracks.isEmpty, tracks.count == sources.count, tracks.count <= 4 else { throw RecordingExportError.noVideo }
        let multiclip = element("multiclip", id: "prosio-native-multicam")
        multiclip.addChild(text("name", session.title)); multiclip.addChild(text("collapsed", "FALSE")); multiclip.addChild(text("synctype", "1"))
        let format = try video.nodes(forXPath: "format").first
        for (index, track) in tracks.enumerated() {
            let nested = element("sequence", id: "angle-sequence-\(index)")
            nested.addChild(text("name", sources[index].name)); nested.addChild(text("duration", duration)); nested.addChild(clone(rate))
            let nestedMedia = element("media"); let nestedVideo = element("video")
            if let format { nestedVideo.addChild(clone(format)) }
            nestedVideo.addChild(clone(track)); nestedMedia.addChild(nestedVideo); nested.addChild(nestedMedia)
            let angleClip = element("clip", id: "angle-clip-\(index)")
            angleClip.addChild(text("name", sources[index].name)); angleClip.addChild(text("duration", duration)); angleClip.addChild(clone(rate)); angleClip.addChild(text("in", "0")); angleClip.addChild(text("out", duration)); angleClip.addChild(text("defaultangle", "\(index + 1)"))
            let angleMedia = element("media"); let angleVideo = element("video"); let angleTrack = element("track")
            let nestedClip = timelineClip(id: "nested-clip-\(index)", name: sources[index].name, duration: duration, rate: rate)
            nestedClip.addChild(nested)
            let sourceTrack = element("sourcetrack"); sourceTrack.addChild(text("mediatype", "video")); nestedClip.addChild(sourceTrack)
            angleTrack.addChild(nestedClip); angleVideo.addChild(angleTrack); angleMedia.addChild(angleVideo); angleClip.addChild(angleMedia)
            let angle = element("angle")
            angle.addChild(text("activevideoangle", index == 0 ? "TRUE" : "FALSE")); angle.addChild(text("activeaudioangle", "FALSE")); angle.addChild(angleClip); multiclip.addChild(angle)
        }
        for track in tracks { track.detach() }
        let mainTrack = element("track")
        let mainClip = timelineClip(id: "prosio-multicam-clip", name: session.title, duration: duration, rate: rate)
        mainClip.addChild(multiclip); mainClip.addChild(text("mediadelay", "0")); mainTrack.addChild(mainClip); video.addChild(mainTrack)
        document.isStandalone = false
        // Original independent audio tracks remain siblings of the single multicam track.
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func timelineClip(id: String, name: String, duration: String, rate: XMLNode) -> XMLElement {
        let clip = element("clipitem", id: id)
        for (key, value) in [("name", name), ("duration", duration), ("start", "0"), ("end", duration), ("in", "0"), ("out", duration)] { clip.addChild(text(key, value)) }
        clip.addChild(clone(rate))
        return clip
    }
    private static func element(_ name: String, id: String? = nil) -> XMLElement {
        let node = XMLElement(name: name)
        if let id { node.addAttribute(XMLNode.attribute(withName: "id", stringValue: id) as! XMLNode) }
        return node
    }
    private static func text(_ name: String, _ value: String) -> XMLElement { XMLElement(name: name, stringValue: value) }
    private static func clone(_ node: XMLNode) -> XMLNode { node.copy() as! XMLNode }
}
