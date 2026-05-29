import Foundation
import AppKit
import UniformTypeIdentifiers

struct SpeechAppProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var videoURL: URL?
    var audioURLs: [URL]
    var narrations: [ProjectNarration]
    var subtitleStyle: SubtitleStyleSettings
    var tracks: [TrackDescriptor]
    var narrationClips: [NarrationClip]
    var mediaClips: [MediaClip]
    var videoAudioMuted: Bool
    var videoAudioVolume: Float
    var exportSettings: ExportSettings

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.videoURL = nil
        self.audioURLs = []
        self.narrations = []
        self.subtitleStyle = SubtitleStyleSettings()
        self.tracks = TrackDescriptor.defaultTracks()
        self.narrationClips = []
        self.mediaClips = []
        self.videoAudioMuted = false
        self.videoAudioVolume = 1.0
        self.exportSettings = ExportSettings()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case videoURL
        case audioURLs
        case narrations
        case subtitleStyle
        case tracks
        case narrationClips
        case mediaClips
        case videoAudioMuted
        case videoAudioVolume
        case exportSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.videoURL = try container.decodeIfPresent(URL.self, forKey: .videoURL)
        self.audioURLs = try container.decodeIfPresent([URL].self, forKey: .audioURLs) ?? []
        self.narrations = try container.decodeIfPresent([ProjectNarration].self, forKey: .narrations) ?? []
        self.subtitleStyle = try container.decodeIfPresent(SubtitleStyleSettings.self, forKey: .subtitleStyle) ?? SubtitleStyleSettings()
        let decodedTracks = try container.decodeIfPresent([TrackDescriptor].self, forKey: .tracks) ?? []
        self.tracks = decodedTracks.isEmpty ? TrackDescriptor.defaultTracks() : decodedTracks.sorted { $0.order < $1.order }
        self.narrationClips = try container.decodeIfPresent([NarrationClip].self, forKey: .narrationClips) ?? []
        self.mediaClips = try container.decodeIfPresent([MediaClip].self, forKey: .mediaClips) ?? []
        self.videoAudioMuted = try container.decodeIfPresent(Bool.self, forKey: .videoAudioMuted) ?? false
        self.videoAudioVolume = try container.decodeIfPresent(Float.self, forKey: .videoAudioVolume) ?? 1.0
        self.exportSettings = try container.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? ExportSettings()

        migrateLegacyNarrationsIfNeeded()
        removeEmptyNonVideoTracks()
    }

    mutating func addTrack(type: TrackType) -> TrackDescriptor {
        let count = tracks.filter { $0.type == type }.count + 1
        let track = TrackDescriptor(
            type: type,
            name: type.defaultName(index: count),
            colour: type.defaultColour,
            order: tracks.count
        )
        tracks.append(track)
        normalizeTrackOrder()
        return track
    }

    mutating func deleteTrack(id: UUID) {
        guard let track = tracks.first(where: { $0.id == id }), track.type != .video else { return }
        tracks.removeAll { $0.id == id }
        narrationClips.removeAll { $0.trackId == id }
        mediaClips.removeAll { $0.trackId == id }
        normalizeTrackOrder()
    }

    mutating func reorderTrack(id: UUID, to targetOrder: Int) {
        guard let sourceIndex = tracks.firstIndex(where: { $0.id == id }) else { return }
        let track = tracks.remove(at: sourceIndex)
        let clampedOrder = min(max(targetOrder, 0), tracks.count)
        tracks.insert(track, at: clampedOrder)
        normalizeTrackOrder()
    }

    mutating func setTrackSolo(id: UUID, isSolo: Bool) {
        for index in tracks.indices {
            tracks[index].solo = isSolo && tracks[index].id == id
        }
    }

    mutating func moveNarrationClip(id: UUID, to startTime: Double) {
        guard let index = narrationClips.firstIndex(where: { $0.id == id }) else { return }
        narrationClips[index].startTime = max(0, startTime)
    }

    mutating func addNarrationClip(_ clip: NarrationClip) {
        narrationClips.append(clip)
    }

    mutating func deleteNarrationClip(id: UUID) {
        narrationClips.removeAll { $0.id == id }
    }

    func narrationOverlaps(for clip: NarrationClip) -> [NarrationClip] {
        narrationClips.filter { existing in
            existing.id != clip.id &&
            existing.trackId == clip.trackId &&
            existing.startTime < clip.endTime &&
            clip.startTime < existing.endTime
        }
    }

    func autoNudgedStart(for clip: NarrationClip) -> Double {
        var proposedStart = clip.startTime
        var candidate = clip

        while true {
            candidate.startTime = proposedStart
            guard let overlap = narrationOverlaps(for: candidate).sorted(by: { $0.endTime < $1.endTime }).first else {
                return proposedStart
            }
            proposedStart = overlap.endTime
        }
    }

    mutating private func migrateLegacyNarrationsIfNeeded() {
        guard narrationClips.isEmpty, !narrations.isEmpty else { return }

        let narrationTrack = tracks.first(where: { $0.type == .narration }) ?? addTrack(type: .narration)
        narrationClips = narrations.enumerated().map { index, narration in
            NarrationClip(
                trackId: narrationTrack.id,
                startTime: index == 0 ? 0 : narrations.prefix(index).reduce(0) { $0 + $1.duration },
                audioFilePath: narration.url.path(percentEncoded: false),
                text: narration.transcript,
                words: WordTiming.words(for: narration, style: subtitleStyle)
            )
        }
    }

    mutating private func normalizeTrackOrder() {
        tracks = tracks.enumerated().map { index, track in
            var updatedTrack = track
            updatedTrack.order = index
            return updatedTrack
        }
    }

    mutating private func removeEmptyNonVideoTracks() {
        let usedTrackIDs = Set(narrationClips.map(\.trackId) + mediaClips.map(\.trackId))
        tracks.removeAll { track in
            track.type != .video && !usedTrackIDs.contains(track.id)
        }
        normalizeTrackOrder()
    }
}

struct TrackDescriptor: Identifiable, Codable, Hashable {
    var id: UUID
    var type: TrackType
    var name: String
    var colour: String
    var muted: Bool
    var solo: Bool
    var hidden: Bool
    var locked: Bool
    var volume: Float
    var order: Int
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        type: TrackType,
        name: String,
        colour: String,
        muted: Bool = false,
        solo: Bool = false,
        hidden: Bool = false,
        locked: Bool = false,
        volume: Float = 1.0,
        order: Int,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.colour = colour
        self.muted = muted
        self.solo = solo
        self.hidden = hidden
        self.locked = locked
        self.volume = volume
        self.order = order
        self.isExpanded = isExpanded
    }

    static func defaultTracks() -> [TrackDescriptor] {
        [
            TrackDescriptor(type: .video, name: "Video", colour: TrackType.video.defaultColour, order: 0)
        ]
    }
}

enum TrackType: String, Codable, CaseIterable, Hashable {
    case video
    case narration
    case music
    case sfx
    case subtitleOverride

    func defaultName(index: Int) -> String {
        switch self {
        case .video: "Video"
        case .narration: "Narration \(index)"
        case .music: "Music \(index)"
        case .sfx: "Sound FX \(index)"
        case .subtitleOverride: "Subtitle Override"
        }
    }

    var defaultColour: String {
        switch self {
        case .video: "#2F6BFF"
        case .narration: "#F0645F"
        case .music: "#76B66C"
        case .sfx: "#557DE8"
        case .subtitleOverride: "#9A5ADE"
        }
    }
}

struct NarrationClip: Identifiable, Codable, Hashable {
    var id: UUID
    var trackId: UUID
    var startTime: Double
    var audioFilePath: String
    var text: String
    var words: [WordTiming]
    var subtitleStyleOverride: SubtitleStyleSettings?

    init(
        id: UUID = UUID(),
        trackId: UUID,
        startTime: Double,
        audioFilePath: String,
        text: String,
        words: [WordTiming],
        subtitleStyleOverride: SubtitleStyleSettings? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.startTime = startTime
        self.audioFilePath = audioFilePath
        self.text = text
        self.words = words
        self.subtitleStyleOverride = subtitleStyleOverride
    }

    var duration: Double {
        words.last.map { $0.startTime + $0.duration } ?? 0
    }

    var endTime: Double {
        startTime + duration
    }

    func withStartTime(_ startTime: Double) -> NarrationClip {
        var clip = self
        clip.startTime = startTime
        return clip
    }
}

struct WordTiming: Codable, Hashable {
    var word: String
    var startTime: Double
    var duration: Double

    static func words(for narration: ProjectNarration, style: SubtitleStyleSettings) -> [WordTiming] {
        ExportTimingBuilder.wordTimings(for: narration, mode: style.timingMode).map { word in
            WordTiming(
                word: word.word,
                startTime: word.start,
                duration: max(0.01, word.end - word.start)
            )
        }
    }
}

struct MediaClip: Identifiable, Codable, Hashable {
    var id: UUID
    var trackId: UUID
    var startTime: Double
    var duration: Double
    var audioFilePath: String
    var volume: Float
    var fadeInDuration: Double
    var fadeOutDuration: Double
    var loop: Bool

    var endTime: Double {
        startTime + duration
    }
}

struct ExportSettings: Codable, Hashable {
    var outputDirectory: String
    var filenameTemplate: String
    var videoCodec: VideoCodec
    var audioCodec: AudioCodec
    var includeSubtitles: Bool
    var sidecarArtifacts: SidecarArtifactSettings

    init(
        outputDirectory: String = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path(percentEncoded: false) ?? "",
        filenameTemplate: String = "%project_%date",
        videoCodec: VideoCodec = .h264,
        audioCodec: AudioCodec = .aac192,
        includeSubtitles: Bool = true,
        sidecarArtifacts: SidecarArtifactSettings = SidecarArtifactSettings()
    ) {
        self.outputDirectory = outputDirectory
        self.filenameTemplate = filenameTemplate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.includeSubtitles = includeSubtitles
        self.sidecarArtifacts = sidecarArtifacts
    }
}

struct SidecarArtifactSettings: Codable, Hashable {
    var ass: Bool = false
    var wordsJson: Bool = false
    var metadata: Bool = false
}

enum VideoCodec: String, Codable, CaseIterable, Hashable {
    case h264
    case h265
    case prores422
}

enum AudioCodec: String, Codable, CaseIterable, Hashable {
    case aac192
    case aac256
    case pcm
}

struct SubtitleStyleSettings: Codable, Hashable {
    var isWordHighlightingEnabled: Bool
    var timingMode: SubtitleTimingMode
    var fontSize: Double
    var activeWordColorHex: String
    var textColorHex: String
    var outlineColorHex: String
    var timingOffset: Double
    var bottomMargin: Double
    var maxWordsPerLine: Int

    init(
        isWordHighlightingEnabled: Bool = true,
        timingMode: SubtitleTimingMode = .punctuationAware,
        fontSize: Double = 54,
        activeWordColorHex: String = "#FFD84D",
        textColorHex: String = "#FFFFFF",
        outlineColorHex: String = "#000000",
        timingOffset: Double = 0,
        bottomMargin: Double = 58,
        maxWordsPerLine: Int = 6
    ) {
        self.isWordHighlightingEnabled = isWordHighlightingEnabled
        self.timingMode = timingMode
        self.fontSize = fontSize
        self.activeWordColorHex = activeWordColorHex
        self.textColorHex = textColorHex
        self.outlineColorHex = outlineColorHex
        self.timingOffset = timingOffset
        self.bottomMargin = bottomMargin
        self.maxWordsPerLine = maxWordsPerLine
    }

    enum CodingKeys: String, CodingKey {
        case isWordHighlightingEnabled
        case timingMode
        case fontSize
        case activeWordColorHex
        case textColorHex
        case outlineColorHex
        case timingOffset
        case bottomMargin
        case maxWordsPerLine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isWordHighlightingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWordHighlightingEnabled) ?? true
        let timingModeRawValue = try container.decodeIfPresent(String.self, forKey: .timingMode)
        self.timingMode = timingModeRawValue.flatMap(SubtitleTimingMode.init(rawValue:)) ?? .punctuationAware
        self.fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 54
        self.activeWordColorHex = try container.decodeIfPresent(String.self, forKey: .activeWordColorHex) ?? "#FFD84D"
        self.textColorHex = try container.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"
        self.outlineColorHex = try container.decodeIfPresent(String.self, forKey: .outlineColorHex) ?? "#000000"
        self.timingOffset = try container.decodeIfPresent(Double.self, forKey: .timingOffset) ?? 0
        self.bottomMargin = try container.decodeIfPresent(Double.self, forKey: .bottomMargin) ?? 58
        self.maxWordsPerLine = try container.decodeIfPresent(Int.self, forKey: .maxWordsPerLine) ?? 6
    }
}

enum SubtitleTimingMode: String, Codable, CaseIterable, Identifiable {
    case simple
    case punctuationAware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple:
            "Simple"
        case .punctuationAware:
            "Smart"
        }
    }
}

struct ProjectNarration: Codable, Identifiable, Hashable {
    var id: UUID
    var url: URL
    var transcript: String
    var voice: String
    var createdAt: Date
    var duration: Double

    init(url: URL, transcript: String, voice: String, duration: Double) {
        self.id = UUID()
        self.url = url
        self.transcript = transcript
        self.voice = voice
        self.createdAt = Date()
        self.duration = duration
    }
}

struct RecentProject: Codable, Identifiable, Hashable {
    let url: URL
    let lastOpenedAt: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var location: String { url.deletingLastPathComponent().path(percentEncoded: false) }
}

enum ProjectFileStore {
    static let fileExtension = "speechproj"
    private static let recentProjectsKey = "recentProjects"

    @MainActor
    static func createProject() throws -> (SpeechAppProject, URL)? {
        let panel = NSSavePanel()
        panel.title = "Create New Project"
        panel.nameFieldStringValue = "Untitled.\(fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .json]

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let project = SpeechAppProject(name: url.deletingPathExtension().lastPathComponent)
        try save(project, to: url)
        addRecentProject(url)
        return (project, url)
    }

    static func loadProject(from url: URL) throws -> SpeechAppProject {
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder.projectDecoder.decode(SpeechAppProject.self, from: data)
        addRecentProject(url)
        return project
    }

    static func save(_ project: SpeechAppProject, to url: URL) throws {
        var projectToSave = project
        projectToSave.updatedAt = Date()
        let data = try JSONEncoder.projectEncoder.encode(projectToSave)
        try data.write(to: url, options: .atomic)
    }

    static func addRecentProject(_ url: URL) {
        var projects = recentProjects().filter { $0.url != url }
        projects.insert(RecentProject(url: url, lastOpenedAt: Date()), at: 0)
        if projects.count > 12 {
            projects = Array(projects.prefix(12))
        }

        guard let data = try? JSONEncoder.projectEncoder.encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: recentProjectsKey)
    }

    static func recentProjects() -> [RecentProject] {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey),
              let projects = try? JSONDecoder.projectDecoder.decode([RecentProject].self, from: data)
        else {
            return []
        }

        return projects
            .filter { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }
}

private extension JSONEncoder {
    static var projectEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var projectDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
