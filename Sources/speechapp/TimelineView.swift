import SwiftUI
import AppKit

struct TimelineViewShell: View {
    @ObservedObject var model: VideoEditorModel
    @Binding var project: SpeechAppProject
    @Binding var selectedNarrationClipID: UUID?
    let onAddNarration: () -> Void
    let onImportAudioClip: (TrackDescriptor) -> Void
    let onReplaceNarration: () -> Void
    let onDeleteNarration: () -> Void

    private let labelColumnWidth: CGFloat = 248
    private let rulerHeight: CGFloat = 28
    private let trackHeight: CGFloat = 56
    @State private var trackPendingDeletion: TrackDescriptor?
    @State private var dragStartTimes: [UUID: Double] = [:]
    @State private var dragPreviewStartTimes: [UUID: Double] = [:]
    @State private var mediaDragStartTimings: [UUID: (startTime: Double, duration: Double)] = [:]
    @State private var mediaPreviewTimings: [UUID: (startTime: Double, duration: Double)] = [:]
    @State private var isDraggingClip = false

    var body: some View {
        VStack(spacing: 0) {
            timelineToolbar
                .frame(height: 48)
            Divider()
            GeometryReader { proxy in
                let timelineWidth = max(proxy.size.width - labelColumnWidth, 1)
                let canvasHeight = rulerHeight + trackHeight * CGFloat(project.tracks.count)
                let progress = progressValue
                let playheadX = labelColumnWidth + timelineWidth * progress

                ZStack(alignment: .topLeading) {
                    timelineBackground

                    VStack(spacing: 0) {
                        ruler(timelineWidth: timelineWidth)
                            .frame(height: rulerHeight)

                        ForEach(project.tracks.sorted(by: { $0.order < $1.order })) { track in
                            trackRow(track, timelineWidth: timelineWidth)
                                .frame(height: trackHeight)
                        }
                    }

                    playhead
                        .position(x: playheadX, y: canvasHeight / 2)
                }
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete Track", isPresented: deleteTrackAlertBinding, presenting: trackPendingDeletion) { track in
            Button("Cancel", role: .cancel) {
                trackPendingDeletion = nil
            }
            Button("Delete Track", role: .destructive) {
                project.deleteTrack(id: track.id)
                if let selectedNarrationClipID,
                   !project.narrationClips.contains(where: { $0.id == selectedNarrationClipID }) {
                    self.selectedNarrationClipID = nil
                }
                trackPendingDeletion = nil
            }
        } message: { track in
            Text("Delete this track and all \(clipCount(for: track)) clips on it? This cannot be undone.")
        }
    }

    private var timelineToolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Add Narration Track") { _ = project.addTrack(type: .narration) }
                Button("Add Music Track") { _ = project.addTrack(type: .music) }
                Button("Add Sound FX Track") { _ = project.addTrack(type: .sfx) }
                Button("Add Subtitle Override Track") { _ = project.addTrack(type: .subtitleOverride) }
            } label: {
                Label("Add Track", systemImage: "plus")
            }
            .menuStyle(.button)

            Button(action: onAddNarration) {
                Label("Add Narration", systemImage: "mic.badge.plus")
            }

            HStack(spacing: 10) {
                Button(action: {}) { Image(systemName: "scissors") }
                Button(action: {}) { Image(systemName: "doc.on.doc") }
                Button(role: .destructive, action: onDeleteNarration) { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)

            if overlapCount > 0 {
                Label("\(overlapCount) Overlap Warning", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            Text("Project Duration: \(formatTimecode(model.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("30 fps")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "minus.magnifyingglass")
            Slider(value: .constant(0.44), in: 0...1)
                .frame(width: 110)
            Image(systemName: "plus.magnifyingglass")
        }
        .padding(.horizontal, 18)
    }

    private var timelineBackground: some View {
        Rectangle()
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private func ruler(timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: labelColumnWidth)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))

                ForEach(rulerTicks(timelineWidth: timelineWidth), id: \.self) { second in
                    let x = tickX(second: second, width: timelineWidth)
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.42))
                            .frame(width: 1, height: 12)
                        Text(formatTimelineTick(second))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .position(x: x, y: 17)
                }
            }
            .frame(width: timelineWidth)
            .contentShape(Rectangle())
            .onTapGesture { location in
                seek(canvasX: location.x, timelineWidth: timelineWidth)
            }
        }
    }

    private func trackRow(_ track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            TrackHeaderView(
                track: binding(for: track),
                videoAudioMuted: $project.videoAudioMuted,
                videoAudioVolume: $project.videoAudioVolume,
                onSolo: { isSolo in
                    project.setTrackSolo(id: track.id, isSolo: isSolo)
                },
                onDelete: {
                    trackPendingDeletion = track
                }
            )
                .frame(width: labelColumnWidth)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(track.type == .video ? Color.blue.opacity(0.04) : Color(nsColor: .textBackgroundColor))

                switch track.type {
                case .video:
                    if model.selectedVideoURL != nil {
                        videoClip(track: track, timelineWidth: timelineWidth)
                    }
                case .narration:
                    ForEach(project.narrationClips.filter { $0.trackId == track.id }) { clip in
                        narrationClip(clip, track: track, timelineWidth: timelineWidth)
                    }
                case .music, .sfx:
                    let clips = project.mediaClips.filter { $0.trackId == track.id }
                    if clips.isEmpty {
                        mediaPlaceholder(track: track, timelineWidth: timelineWidth)
                            .onTapGesture {
                                onImportAudioClip(track)
                            }
                    } else {
                        ForEach(clips) { clip in
                            mediaClip(clip, track: track, timelineWidth: timelineWidth)
                        }
                    }
                case .subtitleOverride:
                    subtitleOverridePlaceholder(track: track, timelineWidth: timelineWidth)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 1)
            }
            .frame(width: timelineWidth)
            .contentShape(Rectangle())
            .onTapGesture { location in
                seek(canvasX: location.x, timelineWidth: timelineWidth)
            }
        }
    }

    private func videoClip(track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(0.82))
            .frame(width: timelineWidth - 12, height: 42)
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    ForEach(0..<28, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index.isMultiple(of: 2) ? .white.opacity(0.26) : .black.opacity(0.10))
                            .frame(width: 22, height: 30)
                    }
                    Spacer()
                    Text(model.selectedVideoURL?.lastPathComponent ?? "Video")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, 10)
                }
                .padding(.leading, 8)
            }
            .padding(.leading, 10)
    }

    private func narrationClip(_ clip: NarrationClip, track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        let originalX = xPosition(for: clip.startTime, width: timelineWidth)
        let previewStartTime = dragPreviewStartTimes[clip.id]
        let previewClip = clip.withStartTime(previewStartTime ?? clip.startTime)
        let previewX = previewStartTime.map { xPosition(for: $0, width: timelineWidth) }
        let width = max(96, durationWidth(clip.duration, width: timelineWidth))

        return ZStack(alignment: .leading) {
            narrationClipBlock(
                clip: clip,
                track: track,
                width: width,
                isSelected: selectedNarrationClipID == clip.id,
                hasOverlap: !project.narrationOverlaps(for: clip).isEmpty
            )
            .opacity(previewStartTime == nil ? 1 : 0.32)
            .offset(x: originalX)
            .onTapGesture {
                selectedNarrationClipID = clip.id
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard !track.locked else { return }
                        if dragStartTimes[clip.id] == nil {
                            dragStartTimes[clip.id] = clip.startTime
                            selectedNarrationClipID = clip.id
                            isDraggingClip = true
                        }
                        let secondsDelta = Double(value.translation.width / timelineWidth) * max(model.duration, clip.duration, 1)
                        let proposed = (dragStartTimes[clip.id] ?? clip.startTime) + secondsDelta
                        dragPreviewStartTimes[clip.id] = clampedStartTime(proposed, for: clip)
                    }
                    .onEnded { _ in
                        if let previewStartTime = dragPreviewStartTimes[clip.id] {
                            let committedStartTime = snappedStartTime(previewStartTime, for: clip)
                            project.moveNarrationClip(id: clip.id, to: committedStartTime)
                        }
                        dragStartTimes[clip.id] = nil
                        dragPreviewStartTimes[clip.id] = nil
                        isDraggingClip = false
                    }
            )

            if let previewX {
                narrationClipBlock(
                    clip: clip,
                    track: track,
                    width: width,
                    isSelected: true,
                    hasOverlap: !project.narrationOverlaps(for: previewClip).isEmpty
                )
                .opacity(0.82)
                .offset(x: previewX)
                .allowsHitTesting(false)
            }
        }
        .frame(width: timelineWidth, height: 42, alignment: .leading)
        .contextMenu {
                Button("Play Clip") {
                    model.seek(to: clip.startTime)
                    model.togglePlayback()
                }
                Button("Replace Audio", action: onReplaceNarration)
                Button(role: .destructive, action: { project.deleteNarrationClip(id: clip.id) }) {
                    Text("Delete Clip")
                }
        }
        .animation(nil, value: previewStartTime)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func narrationClipBlock(
        clip: NarrationClip,
        track: TrackDescriptor,
        width: CGFloat,
        isSelected: Bool,
        hasOverlap: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(0.78))
            .frame(width: width, height: 42)
            .overlay(alignment: .topLeading) {
                Text(clip.text.isEmpty ? "Narration" : clip.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(hex: track.colour))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: width - 24, alignment: .leading)
                    .background(.white, in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .bottom) {
                WaveformStrip(color: .white.opacity(0.52))
                    .frame(height: 14)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
            }
            .overlay {
                if hasOverlap {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white, lineWidth: 2)
                }
            }
    }

    private func mediaPlaceholder(track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        let sampleWidth = min(timelineWidth * 0.72, 760)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(track.muted ? 0.18 : 0.34))
            .frame(width: sampleWidth, height: 32)
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text("Click to import audio")
                    WaveformStrip(color: Color(hex: track.colour).opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(hex: track.colour).opacity(0.85))
                .padding(.horizontal, 10)
            }
            .padding(.leading, 64)
            .opacity(track.muted ? 0.65 : 1)
    }

    private func mediaClip(_ clip: MediaClip, track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        let previewTiming = mediaPreviewTimings[clip.id]
        let displayClip = previewTiming.map { clip.withTiming(startTime: $0.startTime, duration: $0.duration) } ?? clip
        let originalX = xPosition(for: clip.startTime, width: timelineWidth)
        let originalWidth = max(80, durationWidth(clip.duration, width: timelineWidth))
        let previewX = previewTiming.map { xPosition(for: $0.startTime, width: timelineWidth) }
        let previewWidth = previewTiming.map { max(80, durationWidth($0.duration, width: timelineWidth)) }
        let title = URL(fileURLWithPath: clip.audioFilePath).lastPathComponent

        return ZStack(alignment: .leading) {
            mediaClipBlock(
                title: title,
                clip: clip,
                track: track,
                width: originalWidth,
                timelineWidth: timelineWidth,
                showsHandles: previewTiming == nil
            )
            .opacity(previewTiming == nil ? 1 : 0.32)
            .offset(x: originalX)
            .highPriorityGesture(mediaMoveGesture(for: clip, track: track, timelineWidth: timelineWidth))

            if let previewX, let previewWidth {
                mediaClipBlock(
                    title: title,
                    clip: displayClip,
                    track: track,
                    width: previewWidth,
                    timelineWidth: timelineWidth,
                    showsHandles: false
                )
                .opacity(0.82)
                .offset(x: previewX)
                .allowsHitTesting(false)
            }
        }
        .frame(width: timelineWidth, height: 36, alignment: .leading)
        .contextMenu {
            Button("Rename Clip") {}
            Button("Trim to Playhead") {
                trimMediaClipToPlayhead(clip)
            }
            Button(role: .destructive) {
                project.mediaClips.removeAll { $0.id == clip.id }
            } label: {
                Text("Delete Clip")
            }
        }
        .animation(nil, value: previewTiming?.startTime)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func mediaClipBlock(
        title: String,
        clip: MediaClip,
        track: TrackDescriptor,
        width: CGFloat,
        timelineWidth: CGFloat,
        showsHandles: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(track.muted ? 0.28 : 0.64))
            .frame(width: width, height: 36)
            .overlay(alignment: .leading) {
                HStack(spacing: 8) {
                    WaveformStrip(color: .white.opacity(0.42))
                        .frame(width: max(24, width * 0.45))
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
            .overlay(alignment: .leading) {
                if showsHandles {
                    mediaTrimHandle(edge: .leading, clip: clip, track: track, timelineWidth: timelineWidth)
                }
            }
            .overlay(alignment: .trailing) {
                if showsHandles {
                    mediaTrimHandle(edge: .trailing, clip: clip, track: track, timelineWidth: timelineWidth)
                }
            }
    }

    private enum MediaTrimEdge {
        case leading
        case trailing
    }

    private func mediaTrimHandle(edge: MediaTrimEdge, clip: MediaClip, track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.70))
            .frame(width: 6, height: 34)
            .contentShape(Rectangle().inset(by: -5))
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard !track.locked else { return }
                        if mediaDragStartTimings[clip.id] == nil {
                            mediaDragStartTimings[clip.id] = (clip.startTime, clip.duration)
                            isDraggingClip = true
                        }
                        let startTiming = mediaDragStartTimings[clip.id] ?? (clip.startTime, clip.duration)
                        let secondsDelta = seconds(forHorizontalTranslation: value.translation.width, timelineWidth: timelineWidth)
                        mediaPreviewTimings[clip.id] = trimmedTiming(
                            startTiming: startTiming,
                            edge: edge,
                            secondsDelta: secondsDelta
                        )
                    }
                    .onEnded { _ in
                        if let previewTiming = mediaPreviewTimings[clip.id] {
                            project.updateMediaClipTiming(
                                id: clip.id,
                                startTime: previewTiming.startTime,
                                duration: previewTiming.duration
                            )
                        }
                        mediaDragStartTimings[clip.id] = nil
                        mediaPreviewTimings[clip.id] = nil
                        isDraggingClip = false
                    }
            )
    }

    private func mediaMoveGesture(for clip: MediaClip, track: TrackDescriptor, timelineWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard !track.locked else { return }
                if mediaDragStartTimings[clip.id] == nil {
                    mediaDragStartTimings[clip.id] = (clip.startTime, clip.duration)
                    isDraggingClip = true
                }
                let startTiming = mediaDragStartTimings[clip.id] ?? (clip.startTime, clip.duration)
                let secondsDelta = seconds(forHorizontalTranslation: value.translation.width, timelineWidth: timelineWidth)
                mediaPreviewTimings[clip.id] = (
                    startTime: clampedMediaStart(startTiming.startTime + secondsDelta, duration: startTiming.duration),
                    duration: startTiming.duration
                )
            }
            .onEnded { _ in
                if let previewTiming = mediaPreviewTimings[clip.id] {
                    project.updateMediaClipTiming(
                        id: clip.id,
                        startTime: previewTiming.startTime,
                        duration: previewTiming.duration
                    )
                }
                mediaDragStartTimings[clip.id] = nil
                mediaPreviewTimings[clip.id] = nil
                isDraggingClip = false
            }
    }

    private func subtitleOverridePlaceholder(track: TrackDescriptor, timelineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: track.colour).opacity(0.55))
            .frame(width: min(timelineWidth * 0.38, 420), height: 34)
            .overlay(alignment: .leading) {
                Label("Custom subtitle for emphasis", systemImage: "captions.bubble")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
            }
            .padding(.leading, 84)
    }

    private func binding(for track: TrackDescriptor) -> Binding<TrackDescriptor> {
        Binding(
            get: { project.tracks.first(where: { $0.id == track.id }) ?? track },
            set: { updatedTrack in
                guard let index = project.tracks.firstIndex(where: { $0.id == updatedTrack.id }) else { return }
                project.tracks[index] = updatedTrack
            }
        )
    }

    private func trimMediaClipToPlayhead(_ clip: MediaClip) {
        guard model.currentTime > clip.startTime,
              model.currentTime < clip.endTime,
              let index = project.mediaClips.firstIndex(where: { $0.id == clip.id })
        else {
            return
        }

        project.mediaClips[index].duration = model.currentTime - clip.startTime
    }

    private func seconds(forHorizontalTranslation translation: CGFloat, timelineWidth: CGFloat) -> Double {
        Double(translation / timelineWidth) * max(model.duration, 1)
    }

    private func clampedMediaStart(_ proposedStart: Double, duration: Double) -> Double {
        max(0, min(proposedStart, max(model.duration - duration, 0)))
    }

    private func trimmedTiming(
        startTiming: (startTime: Double, duration: Double),
        edge: MediaTrimEdge,
        secondsDelta: Double
    ) -> (startTime: Double, duration: Double) {
        let minimumDuration = 0.1
        switch edge {
        case .leading:
            let originalEnd = startTiming.startTime + startTiming.duration
            let proposedStart = max(0, min(startTiming.startTime + secondsDelta, originalEnd - minimumDuration))
            return (
                startTime: proposedStart,
                duration: max(minimumDuration, originalEnd - proposedStart)
            )
        case .trailing:
            let proposedEnd = max(startTiming.startTime + minimumDuration, startTiming.startTime + startTiming.duration + secondsDelta)
            let clampedEnd = min(max(model.duration, startTiming.startTime + minimumDuration), proposedEnd)
            return (
                startTime: startTiming.startTime,
                duration: max(minimumDuration, clampedEnd - startTiming.startTime)
            )
        }
    }

    private var overlapCount: Int {
        project.narrationClips.reduce(0) { count, clip in
            count + (project.narrationOverlaps(for: clip).isEmpty ? 0 : 1)
        }
    }

    private var deleteTrackAlertBinding: Binding<Bool> {
        Binding(
            get: { trackPendingDeletion != nil },
            set: { if !$0 { trackPendingDeletion = nil } }
        )
    }

    private func clipCount(for track: TrackDescriptor) -> Int {
        project.narrationClips.filter { $0.trackId == track.id }.count +
        project.mediaClips.filter { $0.trackId == track.id }.count
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color(red: 1.0, green: 0.18, blue: 0.20))
                .frame(width: 18, height: 14)
            Rectangle()
                .fill(Color(red: 1.0, green: 0.18, blue: 0.20))
                .frame(width: 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
    }

    private var progressValue: CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(model.currentTime / model.duration, 0), 1))
    }

    private func rulerTicks(timelineWidth: CGFloat) -> [Double] {
        let duration = max(model.duration, 1)
        let targetTickCount = max(2, Int(timelineWidth / 96))
        let rawStep = duration / Double(targetTickCount)
        let step = niceTickStep(for: rawStep)
        let maxTick = Int(ceil(duration / step))
        return (0...maxTick).map { Double($0) * step }.filter { $0 <= duration + step * 0.25 }
    }

    private func tickX(second: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, 1)
        return width * CGFloat(second / total)
    }

    private func niceTickStep(for rawStep: Double) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return candidates.first { $0 >= rawStep } ?? 900
    }

    private func xPosition(for seconds: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, 1)
        return width * CGFloat(seconds / total)
    }

    private func durationWidth(_ duration: Double, width: CGFloat) -> CGFloat {
        let total = max(model.duration, duration, 1)
        return width * CGFloat(duration / total)
    }

    private func snappedStartTime(_ proposedStart: Double, for clip: NarrationClip) -> Double {
        let duration = max(model.duration, clip.duration, 1)
        let snapSeconds = duration * 0.004
        var candidates = [0, model.currentTime]
        candidates.append(contentsOf: project.narrationClips
            .filter { $0.id != clip.id && $0.trackId == clip.trackId }
            .flatMap { [$0.startTime, $0.endTime] })

        guard let nearest = candidates.min(by: { abs($0 - proposedStart) < abs($1 - proposedStart) }),
              abs(nearest - proposedStart) <= snapSeconds
        else {
            return max(0, min(proposedStart, duration))
        }

        return max(0, min(nearest, duration))
    }

    private func clampedStartTime(_ proposedStart: Double, for clip: NarrationClip) -> Double {
        max(0, min(proposedStart, max(model.duration, clip.duration, 1)))
    }

    private func seek(canvasX: CGFloat, timelineWidth: CGFloat) {
        guard model.duration > 0 else { return }
        guard !isDraggingClip else { return }
        let localX = min(max(canvasX, 0), timelineWidth)
        model.seek(to: Double(localX / timelineWidth) * model.duration)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
