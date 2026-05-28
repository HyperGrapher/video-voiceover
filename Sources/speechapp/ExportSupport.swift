import AppKit
import AVFoundation
import Foundation

struct ExportTimedWord: Codable, Hashable, Identifiable {
    let index: Int
    let word: String
    let start: Double
    let end: Double
    let confidence: Double

    var id: Int { index }
}

struct WordsDocument: Codable {
    let text: String
    let sampleRate: Int
    let duration: Double
    let words: [ExportTimedWord]
}

enum ExportTimingBuilder {
    static func buildWordsDocument(
        for narration: ProjectNarration,
        style: SubtitleStyleSettings,
        sampleRate: Int = 24_000
    ) -> WordsDocument {
        let duration = max(narration.duration, 0)
        let words = shiftedTimings(
            wordTimings(for: narration, mode: style.timingMode),
            offset: style.timingOffset
        )
        return WordsDocument(
            text: narration.transcript,
            sampleRate: sampleRate,
            duration: duration,
            words: words
        )
    }

    static func shiftedTimings(_ words: [ExportTimedWord], offset: Double) -> [ExportTimedWord] {
        guard offset != 0 else { return words }

        return words.map { word in
            ExportTimedWord(
                index: word.index,
                word: word.word,
                start: roundedSeconds(max(0, word.start + offset)),
                end: roundedSeconds(max(0.01, word.end + offset)),
                confidence: word.confidence
            )
        }
    }

    static func wordTimings(for narration: ProjectNarration, mode: SubtitleTimingMode) -> [ExportTimedWord] {
        if mode == .forced, !narration.wordTimings.isEmpty {
            return narration.wordTimings
        }

        let fallbackMode: SubtitleTimingMode = mode == .simple ? .simple : .punctuationAware
        return approximateTimings(
            for: narration.transcript,
            duration: max(narration.duration, 0),
            mode: fallbackMode
        )
    }

    static func approximateTimings(
        for transcript: String,
        duration: Double,
        mode: SubtitleTimingMode = .punctuationAware
    ) -> [ExportTimedWord] {
        let tokens = tokenize(transcript)
        guard !tokens.isEmpty, duration > 0 else { return [] }

        let useSmartTiming = mode == .punctuationAware || mode == .forced
        let pauseWeights = tokens.map { useSmartTiming ? pauseWeight(after: $0) : 0 }
        let reservedPause = min(duration * 0.28, pauseWeights.reduce(0, +) * 0.08)
        let spokenDuration = max(duration - reservedPause, duration * 0.72)
        let weights = tokens.map { useSmartTiming ? spokenWeight(for: $0) : Double(max(1, $0.count)) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var current = 0.0
        var result: [ExportTimedWord] = []

        for index in tokens.indices {
            let wordDuration = spokenDuration * weights[index] / totalWeight
            let end: Double
            if index == tokens.count - 1 {
                end = duration
            } else {
                end = min(duration, current + wordDuration)
            }

            result.append(ExportTimedWord(
                index: index,
                word: tokens[index],
                start: roundedSeconds(current),
                end: roundedSeconds(end),
                confidence: 0.4
            ))
            current = min(duration, end + pauseWeights[index] * 0.08)
        }

        return result
    }

    static func tokenize(_ transcript: String) -> [String] {
        transcript
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func roundedSeconds(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func spokenWeight(for token: String) -> Double {
        let stripped = token.trimmingCharacters(in: .punctuationCharacters)
        let characterCount = max(stripped.count, 1)
        let vowelCount = stripped.lowercased().filter { "aeiouy".contains($0) }.count
        let syllableHint = max(1, vowelCount)
        return 0.55 + Double(characterCount) * 0.55 + Double(syllableHint) * 0.75
    }

    private static func pauseWeight(after token: String) -> Double {
        if token.contains("...") || token.contains("…") {
            return 3.0
        }

        guard let last = token.last else { return 0 }
        switch last {
        case ".", "!", "?":
            return 2.2
        case ";", ":":
            return 1.6
        case ",":
            return 1.0
        default:
            return 0
        }
    }
}

enum ASSSubtitleRenderer {
    static func render(
        words: [ExportTimedWord],
        style: SubtitleStyleSettings,
        width: Int = 1920,
        height: Int = 1080
    ) -> String {
        let groups = groupWords(words, maxWords: style.maxWordsPerLine)
        let events = style.isWordHighlightingEnabled ? groups.flatMap { group in
            group.map { activeWord in
                renderEvent(group, activeWord: activeWord, style: style)
            }
        }.joined(separator: "\n") : groups.map { group in
            renderStaticEvent(group, style: style)
        }.joined(separator: "\n")

        return """
        [Script Info]
        ScriptType: v4.00+
        WrapStyle: 0
        ScaledBorderAndShadow: yes
        PlayResX: \(width)
        PlayResY: \(height)

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,\(Int(style.fontSize.rounded())),\(assColor(style.textColorHex)),\(assColor(style.activeWordColorHex)),\(assColor(style.outlineColorHex)),&H00000000,1,0,0,0,100,100,0,0,1,4,0,2,80,80,\(Int(style.bottomMargin.rounded())),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(events)

        """
    }

    static func groupWords(_ words: [ExportTimedWord], maxWords: Int = 6, maxChars: Int = 42, maxDuration: Double = 3.5) -> [[ExportTimedWord]] {
        var groups: [[ExportTimedWord]] = []
        var current: [ExportTimedWord] = []

        for word in words {
            let candidate = current + [word]
            let candidateText = candidate.map(\.word).joined(separator: " ")
            let candidateDuration = (candidate.last?.end ?? 0) - (candidate.first?.start ?? 0)

            if !current.isEmpty && (candidate.count > maxWords || candidateText.count > maxChars || candidateDuration > maxDuration) {
                groups.append(current)
                current = [word]
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups
    }

    private static func renderEvent(
        _ group: [ExportTimedWord],
        activeWord: ExportTimedWord,
        style: SubtitleStyleSettings
    ) -> String {
        let text = group.enumerated().map { offset, word in
            let prefix = offset == 0 ? "" : " "
            let color = word.index == activeWord.index ? assOverrideColor(style.activeWordColorHex) : assOverrideColor(style.textColorHex)
            return "\(prefix){\\1c\(color)}\(escapeASS(word.word))"
        }.joined()

        return "Dialogue: 0,\(formatASSTime(activeWord.start)),\(formatASSTime(activeWord.end)),Default,,0,0,0,,\(text)"
    }

    private static func renderStaticEvent(_ group: [ExportTimedWord], style: SubtitleStyleSettings) -> String {
        guard let first = group.first, let last = group.last else { return "" }
        let text = group.map { "{\\1c\(assOverrideColor(style.textColorHex))}\(escapeASS($0.word))" }.joined(separator: " ")
        return "Dialogue: 0,\(formatASSTime(first.start)),\(formatASSTime(last.end)),Default,,0,0,0,,\(text)"
    }

    private static func formatASSTime(_ seconds: Double) -> String {
        var centiseconds = max(0, Int((seconds * 100).rounded()))
        let hours = centiseconds / 360_000
        centiseconds %= 360_000
        let minutes = centiseconds / 6_000
        centiseconds %= 6_000
        let wholeSeconds = centiseconds / 100
        centiseconds %= 100
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, wholeSeconds, centiseconds)
    }

    private static func escapeASS(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    static func assColor(_ hexColor: String) -> String {
        let trimmed = hexColor.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6 else { return "&H00FFFFFF" }

        let red = String(trimmed.prefix(2))
        let green = String(trimmed.dropFirst(2).prefix(2))
        let blue = String(trimmed.suffix(2))
        return "&H00\(blue)\(green)\(red)".uppercased()
    }

    private static func assOverrideColor(_ hexColor: String) -> String {
        let trimmed = hexColor.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6 else { return "&HFFFFFF&" }

        let red = String(trimmed.prefix(2))
        let green = String(trimmed.dropFirst(2).prefix(2))
        let blue = String(trimmed.suffix(2))
        return "&H\(blue)\(green)\(red)&".uppercased()
    }
}

struct VideoExportRequest {
    let videoURL: URL
    let narration: ProjectNarration
    let subtitleStyle: SubtitleStyleSettings
    let outputURL: URL
}

struct VideoExportResult {
    let outputURL: URL
    let workDirectory: URL
    let wordsURL: URL
    let subtitlesURL: URL
    let ffmpegLog: String
}

enum VideoExportError: LocalizedError {
    case missingFFmpeg
    case missingFFprobe
    case missingLibass(String)
    case noWords
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFFmpeg:
            "Could not find ffmpeg. Install it locally or add it to the app resources."
        case .missingFFprobe:
            "Could not find ffprobe. Install it locally or add it to the app resources."
        case .missingLibass:
            "FFmpeg was found, but ASS/libass subtitle support was not detected."
        case .noWords:
            "Could not generate subtitle words from the narration text."
        case .processFailed(let log):
            "FFmpeg export failed: \(log)"
        }
    }
}

enum SwiftFFmpegRunner {
    static func exportVideoWithSubtitles(_ request: VideoExportRequest) async throws -> VideoExportResult {
        let tools = try await resolveTools()
        try await verifyLibass(ffmpegURL: tools.ffmpeg)

        let workDirectory = try createWorkDirectory()
        let wordsDocument = ExportTimingBuilder.buildWordsDocument(
            for: request.narration,
            style: request.subtitleStyle
        )
        guard !wordsDocument.words.isEmpty else { throw VideoExportError.noWords }

        let wordsURL = workDirectory.appendingPathComponent("words.json")
        let subtitlesURL = workDirectory.appendingPathComponent("subtitles.ass")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(wordsDocument).write(to: wordsURL, options: .atomic)
        try ASSSubtitleRenderer.render(
            words: wordsDocument.words,
            style: request.subtitleStyle
        ).write(to: subtitlesURL, atomically: true, encoding: .utf8)

        let log = try await runFFmpeg(
            ffmpegURL: tools.ffmpeg,
            videoURL: request.videoURL,
            narrationURL: request.narration.url,
            subtitlesURL: subtitlesURL,
            outputURL: request.outputURL
        )

        return VideoExportResult(
            outputURL: request.outputURL,
            workDirectory: workDirectory,
            wordsURL: wordsURL,
            subtitlesURL: subtitlesURL,
            ffmpegLog: log
        )
    }

    static func resolveTools() async throws -> (ffmpeg: URL, ffprobe: URL) {
        guard let ffmpeg = findExecutable(named: "ffmpeg") else {
            throw VideoExportError.missingFFmpeg
        }
        guard let ffprobe = findExecutable(named: "ffprobe") else {
            throw VideoExportError.missingFFprobe
        }
        return (ffmpeg, ffprobe)
    }

    private static func verifyLibass(ffmpegURL: URL) async throws {
        let output = try await runProcess(executableURL: ffmpegURL, arguments: ["-hide_banner", "-filters"])
        if !output.contains(" ass ") && !output.contains(" ass") {
            throw VideoExportError.missingLibass(output)
        }
    }

    private static func runFFmpeg(
        ffmpegURL: URL,
        videoURL: URL,
        narrationURL: URL,
        subtitlesURL: URL,
        outputURL: URL
    ) async throws -> String {
        let arguments = [
            "-y",
            "-hide_banner",
            "-i", videoURL.path(percentEncoded: false),
            "-i", narrationURL.path(percentEncoded: false),
            "-vf", "ass='\(escapeFilterPath(subtitlesURL.path(percentEncoded: false)))'",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "18",
            "-c:a", "aac",
            "-shortest",
            outputURL.path(percentEncoded: false)
        ]

        return try await runProcess(executableURL: ffmpegURL, arguments: arguments)
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let log = [output, error].filter { !$0.isEmpty }.joined(separator: "\n")

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: log)
                    } else {
                        continuation.resume(throwing: VideoExportError.processFailed(log))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func createWorkDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechapp-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let directory = root.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func findExecutable(named name: String) -> URL? {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            currentDirectory.appendingPathComponent("Sources/speechapp/Resources/\(name)"),
            Bundle.main.url(forResource: name, withExtension: nil),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)")
        ].compactMap { $0 }

        return candidates.first { url in
            fileManager.isExecutableFile(atPath: url.path(percentEncoded: false))
        }
    }

    private static func escapeFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
