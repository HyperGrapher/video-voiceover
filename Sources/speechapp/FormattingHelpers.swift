import Foundation

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00:00" }

    let totalSeconds = max(Int(seconds.rounded(.down)), 0)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60

    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
}

func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.00" }

    let centiseconds = max(Int((seconds * 100).rounded()), 0)
    let minutes = centiseconds / 6_000
    let remainingCentiseconds = centiseconds % 6_000
    let wholeSeconds = remainingCentiseconds / 100
    let fraction = remainingCentiseconds % 100
    return String(format: "%02d:%02d.%02d", minutes, wholeSeconds, fraction)
}

func formatTimelineTick(_ seconds: Double) -> String {
    formatTimecode(seconds)
}
