import AppKit
import SwiftUI

// OKLCH design tokens are converted to sRGB for the native renderer.
enum Ink {
    static let primary = adaptive(light: oklch(0.53, 0.11, 80), dark: oklch(0.83, 0.125, 80))
    static let background = Color.black
    static let surface = adaptive(light: oklch(0.94, 0, 0), dark: oklch(0.23, 0, 0))
    static let raised = adaptive(light: oklch(0.985, 0, 0), dark: oklch(0.29, 0, 0))
    static let text = Color.primary
    static let muted = adaptive(light: oklch(0.46, 0, 0), dark: oklch(0.86, 0, 0))
    static let success = adaptive(light: oklch(0.46, 0.12, 155), dark: oklch(0.82, 0.15, 155))
    static let failure = adaptive(light: oklch(0.52, 0.16, 25), dark: oklch(0.78, 0.14, 25))
    static let selection = adaptive(light: .white.opacity(0.65), dark: .white.opacity(0.12))
    static let inset = adaptive(light: .black.opacity(0.035), dark: .white.opacity(0.035))
    static let separator = adaptive(light: .black.opacity(0.08), dark: .white.opacity(0.10))
    static let keycap = adaptive(light: .black.opacity(0.045), dark: .white.opacity(0.07))
    static let editor = adaptive(light: .white.opacity(0.24), dark: .black.opacity(0.12))

    // Keep colors dynamic: resolving the system appearance once at launch would
    // leave custom text and fills stale after an automatic macOS theme change.
    static func adaptive(light: Color, dark: Color) -> Color {
        let lightColor = NSColor(light), darkColor = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
    static func oklch(_ l: Double, _ c: Double, _ h: Double) -> Color {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let ll = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ x: Double) -> Double { min(1, max(0, x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)) }
        return Color(.sRGB, red: gamma(4.0767416621 * ll - 3.3077115913 * m + 0.2309699292 * s), green: gamma(-1.2684380046 * ll + 2.6097574011 * m - 0.3413193965 * s), blue: gamma(-0.0041960863 * ll - 0.7034186147 * m + 1.7076147010 * s))
    }
}

struct NotchRootView: View {
    @ObservedObject var store: FlowStore
    @ObservedObject var state: PanelState
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var agents: AgentMonitor
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                expandedHeader
                ExpandedContent(store: store, state: state, spotify: spotify, agents: agents)
                    .frame(height: 350)
                .opacity(state.expanded ? 1 : 0)
                .offset(y: state.expanded || state.reduceMotion ? 0 : -12)
            }
            .frame(width: state.panelWidth)
            .opacity(state.expanded ? 1 : 0)
            .allowsHitTesting(state.expanded)
            .accessibilityHidden(!state.expanded)
            compact
                .frame(width: state.compactWidth, height: state.notchHeight + 8)
                .opacity(state.expanded ? 0 : 1)
                .allowsHitTesting(!state.expanded)
                .accessibilityHidden(state.expanded)
        }
        .frame(width: state.expanded ? state.panelWidth : state.compactWidth,
               height: state.expanded ? state.notchHeight + 350 : state.notchHeight + 8, alignment: .top)
        .clipShape(NotchShape(cornerRadius: state.expanded ? 26 : 18))
        .background(PanelMaterial(reduceTransparency: state.reduceTransparency)
            .clipShape(NotchShape(cornerRadius: state.expanded ? 26 : 18)).allowsHitTesting(false))
        .modifier(PanelGlass(reduceTransparency: state.reduceTransparency,
                            radius: state.expanded ? 26 : 18))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .fill(.black)
                .frame(width: state.notchWidth, height: state.notchHeight + 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(NotchShape(cornerRadius: state.expanded ? 26 : 18))
        .foregroundStyle(Ink.text)
        .onHover { state.hover?($0) }
        .onExitCommand { state.close?() }
        .frame(width: state.canvasExpanded ? state.panelWidth : state.compactWidth,
               height: state.canvasExpanded ? state.notchHeight + 350 : state.notchHeight + 8, alignment: .top)
        .environment(\.flowReduceMotion, state.reduceMotion)
        .environment(\.flowReduceTransparency, state.reduceTransparency)
        .transaction { if state.reduceMotion { $0.disablesAnimations = true } }
    }

    var expandedHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon).resizable().scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(Ink.text.opacity(0.88))
                        .accessibilityHidden(true)
                }
                Text("Broschy").font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: state.notchWidth)
            HStack(spacing: 2) {
                Menu {
                    Button("Hide panel") { state.close?() }
                    Divider()
                    Button("Quit Broschy") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("App menu")
                .accessibilityLabel("App menu")
                Button { withAnimation(state.reduceMotion ? nil : FlowMotion.feedback) { state.pinned.toggle() } } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(state.pinned ? Ink.primary : Ink.muted)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(QuietButtonStyle())
                .help(state.pinned ? "Unpin panel" : "Keep panel open")
                .accessibilityLabel(state.pinned ? "Unpin panel" : "Pin panel")
                Button { state.close?() } label: { Image(systemName: "chevron.up").foregroundStyle(Ink.muted).frame(width: 28, height: 26) }
                    .buttonStyle(QuietButtonStyle()).help("Hide · Esc").accessibilityLabel("Hide panel")
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
        }
        .frame(height: state.notchHeight)
    }

    var compact: some View {
        Button {
            if state.showsCompactAgents { state.tab = 4 }
            else if compactTrack != nil { state.tab = 3 }
            state.open?()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Group {
                        if state.showsCompactAgents {
                            CompactAgentsLeading(monitor: agents, reduceMotion: state.reduceMotion, isVisible: !state.expanded)
                        } else if let track = compactTrack {
                            CompactMusicArtwork(track: track, isVisible: !state.expanded,
                                                reduceMotion: state.reduceMotion, height: state.notchHeight)
                        } else {
                            Image(systemName: compactSymbol)
                                .contentTransition(.symbolEffect(.replace))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(compactColor)
                        }
                    }
                    .frame(width: compactWingWidth)
                    Color.clear.frame(width: state.notchWidth)
                    Group {
                        if state.showsCompactAgents {
                            CompactAgentsTrailing(monitor: agents)
                        } else if let track = compactTrack {
                            CompactMusicDetails(track: track, isVisible: !state.expanded,
                                                reduceMotion: state.reduceMotion, height: state.notchHeight)
                        } else {
                            Text(compactText)
                                .contentTransition(.numericText(countsDown: true))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(compactColor)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: compactWingWidth)
                }
                .frame(height: state.notchHeight)
                GeometryReader { proxy in
                    if store.timerState.isRunning || store.timerState.didFinish {
                        Capsule().fill(Ink.primary)
                            .frame(width: max(2, proxy.size.width * timerProgress), height: 2)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(state.reduceMotion ? nil : .easeOut(duration: 0.22), value: compactSymbol)
        .animation(state.reduceMotion ? nil : .easeOut(duration: 0.22), value: compactText)
        .accessibilityLabel(compactLabel)
        .help(compactTrack.map { "\($0.title) — \($0.artist) · Click to open Music" }
              ?? "Broschy — hover or click to open")
    }

    var compactWingWidth: CGFloat { max(0, (state.compactWidth - state.notchWidth) / 2) }
    var compactTrack: SpotifySnapshot? {
        !state.showsCompactAgents && state.showsCompactMusic && spotify.status == .connected ? spotify.snapshot : nil
    }
    var compactLabel: String {
        if state.showsCompactAgents { return "Open Agents. \(agents.workingCount) working, \(agents.needsYouCount) need your attention." }
        guard let track = compactTrack else { return "Open Broschy. \(compactText)" }
        return "\(track.isPlaying ? "Playing" : "Paused"): \(track.title) by \(track.artist). Open Music."
    }

    var runningJob: FlowJob? { store.jobs.first(where: { $0.status == .running }) }
    var recentResult: FlowJob? {
        guard let job = store.jobs.filter({ $0.finishedAt != nil }).max(by: { $0.finishedAt! < $1.finishedAt! }),
              let finished = job.finishedAt, Date().timeIntervalSince(finished) < 12 else { return nil }
        return job
    }
    var compactSymbol: String {
        if let job = recentResult { return job.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill" }
        if runningJob != nil { return "terminal" }
        if store.timerState.didFinish { return "checkmark.circle.fill" }
        if store.timerState.hasStarted && store.timerState.remainingSeconds > 0 { return "timer" }
        if spotify.status == .connected && spotify.snapshot?.isPlaying == true { return "waveform" }
        if let job = store.jobs.first { return job.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle" }
        return "circle.hexagongrid.fill"
    }
    var compactText: String {
        if let job = recentResult { return job.status == .succeeded ? "OK" : "Check" }
        if runningJob != nil { return "Running" }
        if store.timerState.didFinish { return "Done" }
        if store.timerState.hasStarted && store.timerState.remainingSeconds > 0 { return clockString(store.timerState.remainingSeconds) }
        if spotify.status == .connected && spotify.snapshot?.isPlaying == true { return "Music" }
        if let job = store.jobs.first { return job.status == .succeeded ? "OK" : "Check" }
        return "Broschy"
    }
    var compactColor: Color {
        if let job = recentResult { return job.status == .succeeded ? Ink.success : Ink.failure }
        if runningJob != nil || (store.timerState.hasStarted && store.timerState.remainingSeconds > 0) { return Ink.primary }
        if store.timerState.didFinish { return Ink.success }
        if spotify.status == .connected && spotify.snapshot?.isPlaying == true { return Ink.success }
        if store.jobs.first?.status == .succeeded { return Ink.success }
        if store.jobs.first?.status == .failed { return Ink.failure }
        return Ink.text
    }
    var timerProgress: Double {
        guard store.timerState.totalSeconds > 0 else { return 0 }
        return min(1, max(0, 1 - Double(store.timerState.remainingSeconds) / Double(store.timerState.totalSeconds)))
    }
}

struct ExpandedContent: View {
    @ObservedObject var store: FlowStore
    @ObservedObject var state: PanelState
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var agents: AgentMonitor
    @Environment(\.flowReduceMotion) var reduceMotion
    @Namespace private var tabSelection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                tab("Agents", symbol: "circle.dotted", index: 4)
                tab("Focus", symbol: "scope", index: 0)
                tab("Music", symbol: "music.note", index: 3)
                tab("Signals", symbol: "terminal", index: 1)
                tab("Later", symbol: "text.alignleft", index: 2)
            }
            .padding(4)
            .modifier(ControlSurface(radius: 14))
            .padding(.top, 12)
            .padding(.horizontal, 20)
            Group {
                switch state.tab {
                case 1: SignalsView(store: store)
                case 2: LaterView(store: store)
                case 3: MusicView(spotify: spotify)
                case 4: AgentsView(monitor: agents, state: state)
                default: FocusView(store: store, state: state)
                }
            }
            .id(state.tab)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 5)),
                removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            HStack {
                if store.storageError != nil {
                    Label("Storage issue", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Ink.failure)
                        .help(store.storageError ?? "")
                } else {
                    Image(systemName: "lock.shield").font(.system(size: 9))
                    Text(state.tab == 3 ? "Spotify on this Mac" : state.tab == 4 ? "Local events · last 24 hours" : "Stored locally")
                }
                Spacer()
                HStack(spacing: 5) {
                    if state.shortcutAvailable { keycap("⌃⌥N") }
                    keycap("esc")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    func tab(_ title: String, symbol: String, index: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : FlowMotion.selection) { state.tab = index }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if (index == 1 && store.jobs.contains(where: { $0.status == .running })) || (index == 4 && agents.needsYouCount > 0) {
                    Circle().fill(Ink.primary).frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if state.tab == index {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.selection)
                        .matchedGeometryEffect(id: "active-tab", in: tabSelection)
                }
            }
            .foregroundStyle(state.tab == index ? Ink.text : Ink.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityAddTraits(state.tab == index ? .isSelected : [])
    }

    func keycap(_ value: String) -> some View {
        Text(value).font(.system(size: 9, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Ink.keycap, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct FocusView: View {
    @ObservedObject var store: FlowStore
    @ObservedObject var state: PanelState
    @FocusState private var editing: Bool
    @Namespace private var durationSelection
    @Environment(\.flowReduceMotion) var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TextField("", text: $store.taskTitle, prompt: Text("What are you working on?").foregroundStyle(Ink.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.text)
                .tint(Ink.primary)
                .multilineTextAlignment(.center)
                .focused($editing)
                .onSubmit { editing = false }
                .accessibilityLabel("Current task")
                .padding(.top, 19)
            Text(time)
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
                .tracking(-1.5)
                .foregroundStyle(store.timerState.didFinish ? Ink.success : Ink.text)
                .contentTransition(.numericText(countsDown: true))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: time)
                .padding(.top, 8)
                .accessibilityLabel("Time remaining \(time)")
            HStack(spacing: 5) {
                if active || store.timerState.didFinish {
                    Image(systemName: store.timerState.didFinish ? "checkmark.circle.fill" : (store.timerState.isRunning ? "circle.fill" : "pause.fill"))
                        .font(.system(size: store.timerState.isRunning ? 5 : 9))
                        .foregroundStyle(store.timerState.didFinish ? Ink.success : Ink.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Ink.muted)
            }
            .padding(.top, 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: subtitle)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.separator)
                    Capsule().fill(store.timerState.didFinish ? Ink.success : Ink.primary)
                        .frame(width: max(0, proxy.size.width * progress))
                        .animation(reduceMotion ? nil : .linear(duration: 0.8), value: progress)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 48)
            .padding(.top, 13)
            .accessibilityHidden(true)
            HStack(spacing: 3) {
                ForEach([25, 50, 90], id: \.self) { value in
                    Button { withAnimation(reduceMotion ? nil : FlowMotion.selection) { state.selectedMinutes = value } } label: {
                        Text("\(value) min")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 17).padding(.vertical, 6)
                            .background {
                                if state.selectedMinutes == value {
                                    Capsule().fill(Ink.selection)
                                        .matchedGeometryEffect(id: "duration", in: durationSelection)
                                }
                            }
                            .foregroundStyle(state.selectedMinutes == value ? Ink.text : Ink.muted)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(active)
                    .accessibilityAddTraits(state.selectedMinutes == value ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Ink.inset, in: Capsule())
            .padding(.top, 12)
            HStack(spacing: 10) {
                Button {
                    editing = false
                    withAnimation(reduceMotion ? nil : FlowMotion.selection) {
                        if active { store.togglePause() } else { store.start(minutes: state.selectedMinutes) }
                    }
                } label: {
                    Label(buttonTitle, systemImage: store.timerState.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity).frame(height: 38)
                }
                .buttonStyle(FlowButtonStyle(primary: true))
                if active || store.timerState.didFinish {
                    Button { withAnimation(reduceMotion ? nil : FlowMotion.selection) { store.resetTimer() } } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 38, height: 38)
                    }
                    .buttonStyle(FlowButtonStyle(primary: false))
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.88)))
                    .help("Reset timer").accessibilityLabel("Reset timer")
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 8)
        }
    }
    var active: Bool { store.timerState.hasStarted && !store.timerState.didFinish && store.timerState.remainingSeconds > 0 }
    var progress: Double {
        guard store.timerState.hasStarted, store.timerState.totalSeconds > 0 else { return 0 }
        return min(1, max(0, 1 - Double(store.timerState.remainingSeconds) / Double(store.timerState.totalSeconds)))
    }
    var time: String { clockString(active || store.timerState.didFinish ? store.timerState.remainingSeconds : state.selectedMinutes * 60) }
    var subtitle: String { store.timerState.didFinish ? "Session complete. Take a breather." : (store.timerState.isRunning ? "Focus in progress" : (active ? "Timer paused" : "One thing at a time.")) }
    var buttonTitle: String { store.timerState.isRunning ? "Pause" : (active ? "Resume" : "Start focus") }
}

struct SignalsView: View {
    @ObservedObject var store: FlowStore
    @State private var copied = false
    @Environment(\.flowReduceMotion) var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Background activity").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { copyExample() } label: {
                    Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 7).padding(.vertical, 6)
                }
                .buttonStyle(QuietButtonStyle()).foregroundStyle(copied ? Ink.success : Ink.muted)
                .help("Copy an example command that reports its result to the notch")
            }
            if store.jobs.isEmpty {
                Spacer(minLength: 0)
                Image(systemName: "terminal").font(.system(size: 26, weight: .light)).foregroundStyle(Ink.primary)
                Text("Let the terminal do its thing.")
                    .font(.system(size: 19, weight: .medium))
                Text("Run tests or builds with Broschy.\nSee when they finish, right here.")
                    .font(.system(size: 12)).foregroundStyle(Ink.muted).lineSpacing(4)
                Button { copyExample() } label: {
                    Label(copied ? "Example copied" : "Copy example for Terminal", systemImage: "arrow.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 34)
                }.buttonStyle(FlowButtonStyle(primary: false))
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.jobs) { job in
                            SignalRow(job: job)
                                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -6)))
                            if job.id != store.jobs.last?.id { Rectangle().fill(Ink.separator).frame(height: 1) }
                        }
                    }
                    .animation(reduceMotion ? nil : FlowMotion.selection, value: store.jobs)
                }
            }
        }
        .padding(.top, 20).padding(.bottom, 12)
    }

    func copyExample() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/broschy-cli").path
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let example = quoted + " run --label 'Broschy test' -- /usr/bin/true"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(example, forType: .string)
        withAnimation(reduceMotion ? nil : FlowMotion.feedback) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(reduceMotion ? nil : FlowMotion.feedback) { copied = false }
        }
    }
}

struct SignalRow: View {
    let job: FlowJob
    @Environment(\.flowReduceMotion) var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 14, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: job.status)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1).help(job.title)
                Text(detail).font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(duration).font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.muted)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
    var symbol: String {
        switch job.status { case .running: return "ellipsis.circle"; case .succeeded: return "checkmark.circle.fill"; case .failed: return "exclamationmark.circle.fill"; case .cancelled: return "stop.circle" }
    }
    var color: Color {
        switch job.status { case .running: return Ink.primary; case .succeeded: return Ink.success; case .failed: return Ink.failure; case .cancelled: return Ink.muted }
    }
    var detail: String {
        let folder = URL(fileURLWithPath: job.workingDirectory).lastPathComponent
        let status: String
        switch job.status { case .running: status = "Running"; case .succeeded: status = "Completed"; case .failed: status = "Failed · exit code \(job.exitCode ?? 1)"; case .cancelled: status = "Cancelled" }
        return folder.isEmpty ? status : status + " · " + folder
    }
    var duration: String {
        let seconds = max(0, Int((job.finishedAt ?? Date()).timeIntervalSince(job.startedAt)))
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct LaterView: View {
    @ObservedObject var store: FlowStore
    @FocusState private var editing: Bool
    @Environment(\.flowReduceMotion) var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture it. Stay focused.").font(.system(size: 15, weight: .semibold))
            Text("An idea, a link, or your next step.")
                .font(.system(size: 11)).foregroundStyle(Ink.muted)
            ZStack(alignment: .topLeading) {
                if store.note.isEmpty {
                    Text("After this session…")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $store.note)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .tint(Ink.primary)
                    .focused($editing)
                    .accessibilityLabel("Note for later")
            }
            .padding(9)
            .background(Ink.editor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Ink.text.opacity(editing ? 0.28 : 0.12), lineWidth: 1))
            .animation(reduceMotion ? nil : FlowMotion.feedback, value: editing)
            Text("Saves automatically · \(store.note.count)/4000")
                .font(.system(size: 10)).foregroundStyle(Ink.muted)
        }
        .padding(.top, 20).padding(.bottom, 14)
    }
}

func clockString(_ seconds: Int) -> String {
    String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
}
