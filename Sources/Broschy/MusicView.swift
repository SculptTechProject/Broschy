import AppKit
import SwiftUI

struct MusicView: View {
    @ObservedObject var spotify: SpotifyController
    @Environment(\.flowReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if spotify.status == .connected, let track = spotify.snapshot {
                player(track)
            } else {
                connection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func player(_ track: SpotifySnapshot) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 13) {
                artwork(track.artworkURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title.isEmpty ? "Nothing playing yet" : track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .help(track.title)
                    Text(track.artist.isEmpty ? "Choose a track in Spotify" : track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(1)
                        .help(track.artist)
                    Text(track.title.isEmpty ? "Ready on Spotify" : (track.isPlaying ? "Playing on Spotify" : "Paused on Spotify"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Open Spotify") { spotify.openSpotify() }
                    Divider()
                    Button("Disconnect Spotify") { spotify.disconnect() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Spotify options")
                .help("Spotify options")
            }

            HStack(spacing: 26) {
                transport("backward.end.fill", label: "Previous track", action: spotify.previousTrack)
                    .disabled(track.id.isEmpty)
                Button(action: spotify.playPause) {
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 68, height: 48)
                }
                .buttonStyle(FlowButtonStyle(primary: true))
                .accessibilityLabel(track.isPlaying ? "Pause Spotify" : "Play Spotify")
                .help(track.isPlaying ? "Pause" : "Play")
                transport("forward.end.fill", label: "Next track", action: spotify.nextTrack)
                    .disabled(track.id.isEmpty)
            }
            .disabled(spotify.busy)
            .animation(reduceMotion ? nil : FlowMotion.feedback, value: track.isPlaying)

            PlaybackPosition(track: track, busy: spotify.busy) { seconds in
                guard spotify.snapshot?.id == track.id else { return }
                spotify.seek(to: seconds)
            }
                .id(track.id)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 11))
                SpotifyVolume(volume: track.volume, busy: spotify.busy, commit: spotify.setVolume)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
            }
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 38)
        }
        .padding(.vertical, 12)
    }

    private func artwork(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Ink.surface
                    Image(systemName: "music.note")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Ink.muted)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    private var connection: some View {
        VStack(spacing: 10) {
            Image(systemName: connectionSymbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Ink.muted)
                .frame(height: 40)
            Text(connectionTitle)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(connectionMessage)
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 310)
            Button(action: connectionAction) {
                HStack(spacing: 7) {
                    if spotify.busy { ProgressView().controlSize(.small) }
                    Text(spotify.busy ? "Connecting…" : connectionButton)
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(minWidth: 146, minHeight: 35)
            }
            .buttonStyle(FlowButtonStyle(primary: true))
            .disabled(spotify.busy)
            .padding(.top, 4)
            if spotify.isEnabled {
                Button("Disconnect") { spotify.disconnect() }
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.muted)
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.vertical, 8)
    }

    private var connectionSymbol: String {
        switch spotify.status {
        case .denied: return "lock.shield"
        case .failure: return "exclamationmark.circle"
        default: return "music.note"
        }
    }
    private var connectionTitle: String {
        switch spotify.status {
        case .notInstalled: return "Spotify is not installed"
        case .notRunning: return "Open Spotify to listen"
        case .denied: return "Allow Spotify control"
        case .failure: return "Spotify is unavailable"
        default: return "Your music, within reach"
        }
    }
    private var connectionMessage: String {
        switch spotify.status {
        case .notInstalled: return "Install the Spotify desktop app, then connect it here."
        case .notRunning: return "Start Spotify on this Mac to see your music and control playback."
        case .denied: return "In Privacy & Security → Automation, allow Broschy to control Spotify."
        case .failure: return spotify.errorMessage ?? "Spotify did not respond. Try connecting again."
        default: return "Play, pause and skip from your notch. macOS will ask you to allow control of Spotify."
        }
    }
    private var connectionButton: String {
        switch spotify.status {
        case .notInstalled: return "Check again"
        case .notRunning: return "Open Spotify"
        case .denied: return "Open Settings"
        case .failure: return "Try again"
        default: return "Connect Spotify"
        }
    }
    private func connectionAction() {
        switch spotify.status {
        case .notRunning: spotify.openSpotify()
        case .denied: spotify.openAutomationSettings()
        default: spotify.connect()
        }
    }
}

private struct PlaybackPosition: View {
    let track: SpotifySnapshot
    let busy: Bool
    let seek: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { draft ?? track.position }, set: { draft = $0 }),
                   in: 0...max(1, track.duration), onEditingChanged: { editing in
                if !editing, let value = draft { seek(value); draft = nil }
            })
            .controlSize(.small)
            .tint(Ink.primary)
            .disabled(busy || track.duration <= 0 || track.id.isEmpty)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(timestamp(draft ?? track.position)) of \(timestamp(track.duration))")
            HStack {
                Text(timestamp(draft ?? track.position))
                Spacer()
                Text(timestamp(track.duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Ink.muted)
            .accessibilityHidden(true)
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(min(86_400_000, max(0, seconds.isFinite ? seconds : 0)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SpotifyVolume: View {
    let volume: Int
    let busy: Bool
    let commit: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        Slider(value: Binding(get: { draft ?? Double(volume) }, set: { draft = $0 }),
               in: 0...100, onEditingChanged: { editing in
            if !editing, let value = draft { commit(Int(value.rounded())); draft = nil }
        })
        .controlSize(.small)
        .tint(Ink.muted)
        .disabled(busy)
        .accessibilityLabel("Spotify volume")
        .accessibilityValue("\(Int(draft ?? Double(volume))) percent")
    }
}
