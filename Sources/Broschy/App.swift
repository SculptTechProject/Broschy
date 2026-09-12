import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class PanelState: ObservableObject {
    static let openDuration: TimeInterval = 0.36
    static let closeDuration: TimeInterval = 0.26

    @Published var expanded = false
    @Published var canvasExpanded = false
    @Published var reduceMotion = false
    @Published var reduceTransparency = false
    @Published var pinned = false
    @Published var hasPresentedPopover = false
    @Published var tab = 0
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var panelWidth: CGFloat = 448
    @Published var showsCompactMusic = false
    @Published var showsCompactAgents = false
    var compactWidth: CGFloat { min(panelWidth, notchWidth + ((showsCompactMusic || showsCompactAgents) ? 264 : 128)) }
    @Published var shortcutAvailable = false
    @Published var selectedMinutes = 25
    var open: (() -> Void)?
    var close: (() -> Void)?
    var hover: ((Bool) -> Void)?
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .init("Broschy.close"), object: nil)
    }
}

final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = FlowStore()
    let state = PanelState()
    let spotify = SpotifyController()
    let agents = AgentMonitor()
    var panel: NotchPanel!
    var statusItem: NSStatusItem!
    var observers: [NSObjectProtocol] = []
    var subscriptions = Set<AnyCancellable>()
    var hoverWork: DispatchWorkItem?
    var transitionWork: DispatchWorkItem?
    var transitionGeneration: UInt = 0
    var wantsExpanded = false
    var pendingCompactMusic = false
    var pendingCompactAgents = false
    var accessibilityObserver: NSObjectProtocol?
    var hotKey: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var localMonitor: Any?
    var selectedScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preserve the original bundle identity so existing preferences and Automation consent remain available.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "pl.local.NotchFlow")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        refreshAccessibilityOptions()
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Broschy"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if #available(macOS 15.0, *) {
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        } else {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        panel.contentView = InteractiveHostingView(rootView: NotchRootView(store: store, state: state, spotify: spotify, agents: agents))
        state.open = { [weak self] in self?.expand(focus: true) }
        state.close = { [weak self] in self?.collapse() }
        state.hover = { [weak self] inside in self?.hover(inside) }
        configureMenu()
        state.selectedMinutes = store.timerState.totalSeconds / 60
        if CommandLine.arguments.contains("--music") { state.tab = 3 }
        if CommandLine.arguments.contains("--agents") { state.tab = 4 }
        registerShortcut()
        updateScreen()
        panel.orderFrontRegardless()
        Publishers.CombineLatest4(spotify.$status, spotify.$snapshot, store.$timerState, store.$jobs)
            .combineLatest(agents.$sessions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] values, sessions in
                guard let self else { return }
                let (status, track, timer, jobs) = values
                let recentResult = jobs.contains { job in
                    guard let finished = job.finishedAt else { return false }
                    return Date().timeIntervalSince(finished) < 12
                }
                let focusOrJob = timer.didFinish || (timer.hasStarted && timer.remainingSeconds > 0)
                    || jobs.contains(where: { $0.status == .running }) || recentResult
                let visible = sessions.filter { $0.updatedAt > Date().addingTimeInterval(-86400) && $0.effectiveStatus() != .closed }
                let agentActivity = visible.contains(where: { $0.needsAttention() })
                    || (!focusOrJob && visible.contains(where: { $0.effectiveStatus() == .working }))
                let music = !agentActivity && !focusOrJob && status == .connected && track?.title.isEmpty == false
                self.updateCompactActivity(music: music, agents: agentActivity)
            }
            .store(in: &subscriptions)

        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibilityOptions() }
        }

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateScreen() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .init("Broschy.close"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsExpanded, !self.panel.isKeyWindow, !self.state.pinned, !self.state.hasPresentedPopover, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.collapse()
            }
        })
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == kVK_ANSI_N && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                self.togglePanel()
                return nil
            }
            if event.type == .keyDown && event.keyCode == 53 {
                self.collapse()
                return nil
            }
            if event.type == .leftMouseDown && event.window === self.panel && self.state.expanded {
                self.panel.makeKey()
            }
            return event
        }
        state.$pinned.dropFirst().sink { [weak self] pinned in
            if pinned { self?.expand(focus: false) }
        }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--expanded") { expand(focus: false) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        expand(focus: true)
        return true
    }

    func refreshAccessibilityOptions() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--reduce-motion")
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || CommandLine.arguments.contains("--reduce-transparency")
        withoutAnimation {
            state.reduceMotion = reduceMotion
            state.reduceTransparency = reduceTransparency
        }
        guard reduceMotion, panel != nil, transitionWork != nil else { return }
        transitionWork?.cancel()
        transitionWork = nil
        transitionGeneration &+= 1
        if wantsExpanded {
            withoutAnimation {
                state.canvasExpanded = true
                state.expanded = true
            }
            position()
        } else {
            finishCollapse(generation: transitionGeneration)
        }
    }

    func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    func updateScreen() {
        selectedScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = selectedScreen else { return }
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let gap = right.minX - left.maxX
        state.notchWidth = screen.safeAreaInsets.top > 0 && gap > 0 ? gap : 180
        state.notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 28
        state.panelWidth = min(480, screen.frame.width - 32)
        position()
    }

    func position() {
        guard let screen = selectedScreen else { return }
        let width = state.canvasExpanded ? state.panelWidth : state.compactWidth
        let height = state.canvasExpanded ? state.notchHeight + 350 : state.notchHeight + 8
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let center = screen.safeAreaInsets.top > 0 && right.minX > left.maxX
            ? (left.maxX + right.minX) / 2 : screen.frame.midX
        panel.setFrame(NSRect(x: center - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
    }

    func expand(focus: Bool) {
        hoverWork?.cancel()
        guard !wantsExpanded else {
            panel.orderFrontRegardless()
            if focus { panel.makeKey() }
            return
        }
        wantsExpanded = true
        transitionWork?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        // Reserve the full native window before SwiftUI grows the visible surface.
        withoutAnimation { state.canvasExpanded = true }
        position()
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsExpanded, self.transitionGeneration == generation else { return }
            self.transitionWork = nil
            if self.state.reduceMotion {
                self.withoutAnimation { self.state.expanded = true }
            } else {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: PanelState.openDuration)) {
                    self.state.expanded = true
                }
            }
        }
        transitionWork = work
        if state.reduceMotion { work.perform() }
        else { DispatchQueue.main.async(execute: work) }
    }

    func collapse() {
        hoverWork?.cancel()
        guard wantsExpanded else { return }
        wantsExpanded = false
        transitionWork?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        state.pinned = false
        panel.makeFirstResponder(nil)
        if state.reduceMotion {
            withoutAnimation { state.expanded = false }
            finishCollapse(generation: generation)
            return
        }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: PanelState.closeDuration)) {
            state.expanded = false
        }
        // Keep the canvas until the surface has closed, then stop intercepting
        // clicks in the now-empty area. A new opening invalidates this shrink.
        let work = DispatchWorkItem { [weak self] in
            self?.finishCollapse(generation: generation)
        }
        transitionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelState.closeDuration, execute: work)
    }

    func finishCollapse(generation: UInt) {
        guard !wantsExpanded, transitionGeneration == generation else { return }
        transitionWork = nil
        withoutAnimation {
            state.showsCompactMusic = pendingCompactMusic
            state.showsCompactAgents = pendingCompactAgents
            state.canvasExpanded = false
        }
        // Ordering out releases AppKit/window-server focus correctly; doing this
        // after the animation keeps keyboard-driven closing visually continuous.
        if panel.isKeyWindow { panel.orderOut(nil) }
        position()
        panel.orderFrontRegardless()
    }

    func updateCompactActivity(music: Bool, agents: Bool) {
        pendingCompactMusic = music
        pendingCompactAgents = agents
        // Keep the closing surface stable; apply new activity when it settles.
        guard wantsExpanded || !state.canvasExpanded else { return }
        guard state.showsCompactMusic != music || state.showsCompactAgents != agents else { return }
        withoutAnimation {
            state.showsCompactMusic = music
            state.showsCompactAgents = agents
        }
        position()
    }

    func hover(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if inside {
                self.expand(focus: false)
            } else if !self.state.pinned && !self.state.hasPresentedPopover && !self.panel.isKeyWindow {
                self.collapse()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.45), execute: work)
    }

    func configureMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Broschy")
        let terminate = NSMenuItem(title: "Quit Broschy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(terminate)
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "inset.filled.topcenter.rectangle", accessibilityDescription: "Broschy")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show / Hide Panel", action: #selector(togglePanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Broschy Data", action: #selector(showData), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Broschy", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func togglePanel() {
        if wantsExpanded { collapse() } else { expand(focus: true) }
    }
    @objc func showData() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        // Keep the existing support folder so a rename does not orphan notes, timers, or jobs.
        NSWorkspace.shared.open(support.appendingPathComponent("NotchFlow", isDirectory: true))
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    func registerShortcut() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }, 1, &eventType, userData, &hotKeyHandler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x4E464C57), id: 1)
        state.shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
        hoverWork?.cancel()
        transitionWork?.cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

@main
struct BroschyMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
