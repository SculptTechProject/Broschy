import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class PanelState: ObservableObject {
    static let openDuration: TimeInterval = 0.36
    static let closeDuration: TimeInterval = 0.36
    static let previewDuration: TimeInterval = 0.14
    static let hoverDelay: TimeInterval = 0.22

    @Published var expanded = false
    @Published var canvasExpanded = false
    @Published var previewing = false
    @Published var canvasPreview = false
    @Published var reduceMotion = false
    @Published var reduceTransparency = false
    @Published var pinned = false
    @Published var hasAgentPopover = false
    @Published var showsSettings = false
    var hasPresentedPopover: Bool { hasAgentPopover || showsSettings }
    @Published var tab = 0
    @Published var signalPage = 0
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var menuBarHeight: CGFloat = 32
    @Published var panelWidth: CGFloat = 448
    @Published var compactContent = CompactContent.idle
    var showsCompactMusic: Bool { compactContent == .music }
    var showsCompactAgents: Bool { compactContent == .agents }
    var compactWidth: CGFloat { PanelGeometry.compactWidth(notchWidth: notchWidth, panelWidth: panelWidth, wide: compactContent.usesWideWings) }
    var previewWidth: CGFloat { PanelGeometry.previewWidth(compactWidth: compactWidth, panelWidth: panelWidth) }
    var compactHeight: CGFloat { menuBarHeight + (previewing ? PanelGeometry.previewHeightGrowth : 0) }
    var surfaceWidth: CGFloat { expanded ? panelWidth : previewing ? previewWidth : compactWidth }
    var surfaceHeight: CGFloat { expanded ? notchHeight + 350 : compactHeight }
    var canvasWidth: CGFloat { canvasExpanded ? panelWidth + PanelGeometry.animationPadding * 2 : canvasPreview ? previewWidth : compactWidth }
    var canvasHeight: CGFloat { canvasExpanded ? notchHeight + 350 + PanelGeometry.animationPadding : menuBarHeight + (canvasPreview ? PanelGeometry.previewHeightGrowth : 0) }
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
    let preferences = PanelPreferences()
    let builds = BuildWatchMonitor()
    var panel: NotchPanel!
    var statusItem: NSStatusItem!
    var observers: [NSObjectProtocol] = []
    var subscriptions = Set<AnyCancellable>()
    var hoverWork: DispatchWorkItem?
    var previewWork: DispatchWorkItem?
    var hoverGeneration: UInt = 0
    var pointerInside = false
    var suppressHoverUntilExit = false
    var transitionWork: DispatchWorkItem?
    var transitionGeneration: UInt = 0
    var wantsExpanded = false
    var pendingCompactContent = CompactContent.idle
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
        panel.contentView = InteractiveHostingView(rootView: NotchRootView(store: store, state: state, spotify: spotify, agents: agents, preferences: preferences, builds: builds))
        state.open = { [weak self] in self?.expand(focus: true) }
        state.close = { [weak self] in self?.collapse() }
        state.hover = { [weak self] inside in self?.hover(inside) }
        configureMenu()
        state.selectedMinutes = store.timerState.totalSeconds / 60
        if CommandLine.arguments.contains("--music") { state.tab = 3 }
        if CommandLine.arguments.contains("--agents") { state.tab = 4 }
        state.tab = preferences.safeSelection(PanelTab(rawValue: state.tab)).rawValue
        registerShortcut()
        updateScreen()
        panel.orderFrontRegardless()
        // Read the settled models on the next main-queue turn: objectWillChange
        // fires before @Published has assigned its new value.
        Publishers.MergeMany([spotify.objectWillChange.eraseToAnyPublisher(),
                              store.objectWillChange.eraseToAnyPublisher(),
                              agents.objectWillChange.eraseToAnyPublisher(),
                              preferences.objectWillChange.eraseToAnyPublisher(),
                              builds.objectWillChange.eraseToAnyPublisher()])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshCompactActivity() }
            .store(in: &subscriptions)
        refreshCompactActivity()

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
        guard reduceMotion, panel != nil else { return }
        cancelHoverIntent()
        transitionWork?.cancel()
        transitionWork = nil
        transitionGeneration &+= 1
        if wantsExpanded {
            withoutAnimation {
                state.previewing = false
                state.canvasPreview = false
                state.canvasExpanded = true
                state.expanded = true
            }
            position()
        } else {
            finishCollapse(generation: transitionGeneration)
            if pointerInside { hover(true) }
        }
    }

    func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    func updateScreen() {
        cancelHoverIntent()
        suppressHoverUntilExit = false
        transitionWork?.cancel()
        transitionWork = nil
        transitionGeneration &+= 1
        selectedScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = selectedScreen else { return }
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let gap = right.minX - left.maxX
        withoutAnimation {
            state.notchWidth = screen.safeAreaInsets.top > 0 && gap > 0 ? gap : 180
            state.notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 28
            state.menuBarHeight = PanelGeometry.compactHeight(safeAreaTop: screen.safeAreaInsets.top,
                                                            menuBarHeight: NSStatusBar.system.thickness)
            state.panelWidth = min(480, screen.frame.width - 32)
            state.previewing = false
            state.canvasPreview = false
            state.expanded = wantsExpanded
            state.canvasExpanded = wantsExpanded
        }
        if wantsExpanded { position() }
        else { finishCollapse(generation: transitionGeneration) }
    }

    func position() {
        guard let frame = panelFrame(width: state.canvasWidth, height: state.canvasHeight) else { return }
        panel.setFrame(frame, display: true)
    }

    func panelFrame(width: CGFloat, height: CGFloat) -> CGRect? {
        guard let screen = selectedScreen else { return nil }
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let center = screen.safeAreaInsets.top > 0 && right.minX > left.maxX
            ? (left.maxX + right.minX) / 2 : screen.frame.midX
        return PanelGeometry.frame(centerX: center, screenFrame: screen.frame, width: width, height: height)
    }

    var pointerIsOverCompactPanel: Bool {
        panelFrame(width: state.compactWidth, height: state.menuBarHeight)?.contains(NSEvent.mouseLocation) == true
    }

    func expand(focus: Bool) {
        cancelHoverIntent()
        suppressHoverUntilExit = false
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
            if self.state.reduceMotion {
                self.withoutAnimation {
                    self.state.expanded = true
                    self.state.previewing = false
                    self.state.canvasPreview = false
                }
                self.transitionWork = nil
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.08)) {
                    self.state.expanded = true
                    self.state.previewing = false
                }
                self.withoutAnimation { self.state.canvasPreview = false }
                let settled = DispatchWorkItem { [weak self] in
                    guard let self, self.wantsExpanded, self.transitionGeneration == generation else { return }
                    self.transitionWork = nil
                }
                self.transitionWork = settled
                DispatchQueue.main.asyncAfter(deadline: .now() + PanelState.openDuration, execute: settled)
            }
        }
        transitionWork = work
        if state.reduceMotion { work.perform() }
        else { DispatchQueue.main.async(execute: work) }
    }

    func collapse() {
        cancelHoverIntent()
        // Dismissing under the pointer must survive tracking events generated
        // when the native window shrinks or relinquishes keyboard focus.
        suppressHoverUntilExit = pointerIsOverCompactPanel
        state.showsSettings = false
        guard wantsExpanded else {
            if !state.canvasExpanded { endPreview(generation: hoverGeneration, dismissed: true) }
            return
        }
        wantsExpanded = false
        transitionWork?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        state.pinned = false
        panel.makeFirstResponder(nil)
        if state.reduceMotion {
            withoutAnimation { state.expanded = false; state.previewing = false }
            finishCollapse(generation: generation)
            return
        }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.08)) {
            state.expanded = false
            state.previewing = false
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
        let wasClosing = state.canvasExpanded
        withoutAnimation {
            state.expanded = false
            state.previewing = false
            state.canvasPreview = false
            state.compactContent = pendingCompactContent
            state.canvasExpanded = false
        }
        // Deferred activity can widen the resting panel under a stationary
        // pointer. Treat that new tracking entry as part of the same dismissal.
        if wasClosing && pointerIsOverCompactPanel { suppressHoverUntilExit = true }
        // Ordering out releases AppKit/window-server focus correctly; doing this
        // after the animation keeps keyboard-driven closing visually continuous.
        if panel.isKeyWindow { panel.orderOut(nil) }
        position()
        panel.orderFrontRegardless()
    }

    func refreshCompactActivity() {
        let safeTab = preferences.safeSelection(PanelTab(rawValue: state.tab)).rawValue
        if state.tab != safeTab { state.tab = safeTab }
        let now = Date()
        let timer = store.timerState
        let attention = AgentAttentionPolicy.compactAttention(from: agents.visibleSessions,
            visibleTabs: preferences.visibleTabs, quietFocusEnabled: preferences.quietFocusEnabled,
            focusActive: timer.isRunning, now: now)
        let localActivity = store.jobs.contains { job in
            job.status == .running || job.finishedAt.map { (0..<12).contains(now.timeIntervalSince($0)) } == true
        }
        let recentBuild = builds.compactRepository?.controller.recentCompletion.map {
            (0..<12).contains(now.timeIntervalSince($0.observedAt))
        } == true
        let content = CompactContent.choose(visibleTabs: preferences.visibleTabs,
            quietFocusRunning: preferences.quietFocusEnabled && timer.isRunning,
            agentAttention: !attention.isEmpty, workingAgents: agents.workingCount > 0,
            focusActive: timer.didFinish || (timer.hasStarted && timer.remainingSeconds > 0),
            localActivity: localActivity, recentBuild: recentBuild, activeBuild: builds.activeCount > 0,
            musicAvailable: spotify.status == .connected && spotify.snapshot?.title.isEmpty == false)
        updateCompactActivity(content)
    }

    func updateCompactActivity(_ content: CompactContent) {
        pendingCompactContent = content
        // Keep the closing surface stable; apply new activity when it settles.
        guard wantsExpanded || (!state.canvasExpanded && !state.canvasPreview) else { return }
        guard state.compactContent != content else { return }
        withoutAnimation { state.compactContent = content }
        position()
    }

    func cancelHoverIntent() {
        hoverWork?.cancel()
        hoverWork = nil
        previewWork?.cancel()
        previewWork = nil
        hoverGeneration &+= 1
    }

    func beginPreview(generation: UInt) {
        guard !state.reduceMotion else { return }
        withoutAnimation { state.canvasPreview = true }
        position()
        // Grow the native canvas first, then animate only the visible glass.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation, self.pointerInside, !self.wantsExpanded else { return }
            self.previewWork = nil
            withAnimation(.easeOut(duration: PanelState.previewDuration)) { self.state.previewing = true }
        }
        previewWork = work
        DispatchQueue.main.async(execute: work)
    }

    func endPreview(generation: UInt, dismissed: Bool = false) {
        guard state.canvasPreview else { return }
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation, !self.wantsExpanded, !self.state.canvasExpanded else { return }
            self.previewWork = nil
            self.withoutAnimation {
                self.state.previewing = false
                self.state.canvasPreview = false
                self.state.compactContent = self.pendingCompactContent
            }
            if dismissed && self.pointerIsOverCompactPanel { self.suppressHoverUntilExit = true }
            self.position()
        }
        previewWork = finish
        if state.reduceMotion {
            finish.perform()
        } else {
            withAnimation(.easeOut(duration: PanelState.previewDuration)) { state.previewing = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelState.previewDuration, execute: finish)
        }
    }

    func hover(_ inside: Bool) {
        if suppressHoverUntilExit {
            // AppKit can emit a synthetic exit while rebuilding the tracking
            // region. Only an actual pointer exit enables hover opening again.
            if !inside && !pointerIsOverCompactPanel {
                suppressHoverUntilExit = false
                pointerInside = false
            }
            return
        }
        pointerInside = inside
        cancelHoverIntent()
        let generation = hoverGeneration
        if inside {
            guard !wantsExpanded else { return }
            if state.canvasExpanded { expand(focus: false); return }
            beginPreview(generation: generation)
        } else if !wantsExpanded && !state.canvasExpanded {
            endPreview(generation: generation)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation, self.pointerInside == inside else { return }
            self.hoverWork = nil
            if inside {
                self.expand(focus: false)
            } else if !self.state.pinned && !self.state.hasPresentedPopover && !self.panel.isKeyWindow {
                self.collapse()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? PanelState.hoverDelay : 0.45), execute: work)
    }

    func configureMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Broschy")
        let terminate = NSMenuItem(title: "Quit Broschy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
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
        statusItem.button?.image = StatusBarIcon.makeImage()
        statusItem.button?.toolTip = "Broschy"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show / Hide Panel", action: #selector(togglePanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let customize = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        customize.target = self
        menu.addItem(customize)
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
    @objc func showSettings() {
        expand(focus: true)
        state.showsSettings = true
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
        previewWork?.cancel()
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
