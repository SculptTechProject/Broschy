import SwiftUI

/// The two music wings stay outside the physical camera region.
struct CompactMusicArtwork: View {
    let track: SpotifySnapshot
    let isVisible: Bool
    let reduceMotion: Bool
    let height: CGFloat

    private var artworkSize: CGFloat { min(28, max(18, height - 8)) }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                AsyncImage(url: track.artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Ink.inset
                            Image(systemName: "music.note")
                                .font(.system(size: artworkSize * 0.46, weight: .medium))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Ink.text.opacity(0.12), lineWidth: 0.5)
                }
                .id(track.compactIdentity)
                .transition(.opacity)
            }
            .frame(width: artworkSize, height: artworkSize)
            .animation(reduceMotion || !isVisible ? nil : .easeOut(duration: 0.24), value: track.compactIdentity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(compactMusicTime(track.position))
                        .foregroundStyle(Ink.text)
                    Spacer(minLength: 3)
                    CompactPlaybackBars(isPlaying: track.isPlaying, isVisible: isVisible, reduceMotion: reduceMotion)
                        .frame(width: 19, height: 17)
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.text.opacity(0.16))
                        Capsule().fill(Ink.text.opacity(0.76))
                            .frame(width: geometry.size.width * track.compactProgress)
                    }
                }
                .frame(height: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CompactMusicDetails: View {
    let track: SpotifySnapshot
    let isVisible: Bool
    let reduceMotion: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title.isEmpty ? "Spotify" : track.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.text)
                    Text(track.artist.isEmpty ? (track.isPlaying ? "Playing" : "Paused") : track.artist)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Ink.muted)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(track.compactIdentity)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 3)),
                    removal: .opacity.combined(with: .offset(y: -3))))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .animation(reduceMotion || !isVisible ? nil : .easeOut(duration: 0.24), value: track.compactIdentity)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .help([track.title, track.artist, track.isPlaying ? "Playing on Spotify" : "Paused on Spotify"]
            .filter { !$0.isEmpty }.joined(separator: " — "))
        .accessibilityHidden(true)
    }
}

/// A playback indicator, not an audio visualizer. Only this small canvas redraws.
private struct CompactPlaybackBars: View {
    let isPlaying: Bool
    let isVisible: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24,
                                paused: !isPlaying || !isVisible || reduceMotion)) { context in
            Canvas { drawing, size in
                let animated = isPlaying && isVisible && !reduceMotion
                let time = animated ? context.date.timeIntervalSinceReferenceDate : 0
                let color = isPlaying ? Ink.success : Ink.muted
                let barWidth: CGFloat = 2
                let gap = (size.width - barWidth * 5) / 4
                for index in 0..<5 {
                    let phase = Double(index) * 1.35
                    let wave = (sin(time * (3.2 + Double(index) * 0.3) + phase)
                                + sin(time * 2.15 + phase * 0.7)) / 2
                    let idleHeight = [0.3, 0.65, 1.0, 0.65, 0.3][index]
                    let fraction = animated ? 0.3 + (wave + 1) * 0.35 : (isPlaying ? idleHeight : 0.22)
                    let barHeight = max(3, size.height * fraction)
                    let rect = CGRect(x: CGFloat(index) * (barWidth + gap),
                                      y: (size.height - barHeight) / 2,
                                      width: barWidth, height: barHeight)
                    drawing.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private extension SpotifySnapshot {
    var compactIdentity: String { id.isEmpty ? title + "\u{0}" + artist : id }
    var compactProgress: CGFloat {
        guard duration.isFinite, position.isFinite, duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, position / duration)))
    }
}

private func compactMusicTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let value = Int(seconds)
    return String(format: "%d:%02d", value / 60, value % 60)
}
