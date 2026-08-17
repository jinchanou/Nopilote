import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class PanelController {
    // A regular window stays in the normal window stack when another app is active.
    // NSPanel is designed for transient auxiliary UI and can disappear on deactivation.
    private let panel: NSWindow
    private var pinObservation: AnyCancellable?
    private var reviewWindowController: ReviewWindowController!

    init(model: AppModel) {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Nopilote"
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // A normal, unpinned window belongs only to its current Space. In
        // particular, it must not appear above another app in full screen.
        panel.collectionBehavior = []
        panel.contentMinSize = NSSize(width: 390, height: 520)
        panel.contentViewController = NSHostingController(rootView: NopiloteView().environmentObject(model))
        panel.center()
        reviewWindowController = ReviewWindowController(model: model) { [weak panel] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        }
        pinObservation = model.$isPinned.removeDuplicates().sink { [weak panel] pinned in
            panel?.level = pinned ? .floating : .normal
            panel?.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The first launch should land on the normal desktop even when the app
    /// was opened while another application owns a full-screen Space.
    func showOnDesktop() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            show()
            return
        }

        panel.orderOut(nil)
        _ = finder.activate(options: [.activateAllWindows])
        Task { @MainActor [weak self] in
            // Allow Space activation to settle before activating our window.
            try? await Task.sleep(for: .milliseconds(180))
            self?.show()
        }
    }

    var isAlwaysOnTop: Bool { panel.level == .floating }
}

@MainActor
private final class ReviewWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let showConversation: () -> Void
    private var proposalObservation: AnyCancellable?
    private var pinObservation: AnyCancellable?
    private var window: NSWindow?

    init(model: AppModel, showConversation: @escaping () -> Void) {
        self.model = model
        self.showConversation = showConversation
        super.init()
        proposalObservation = model.$proposal.sink { [weak self] proposal in
            guard let self else { return }
            if let proposal {
                self.show(proposal)
            } else {
                self.close()
            }
        }
        pinObservation = model.$isPinned.removeDuplicates().sink { [weak self] pinned in
            self?.applyWindowLevel(pinned: pinned)
        }
    }

    private func show(_ proposal: EditProposal) {
        let reviewView = ProposalView(
            proposal: proposal,
            showConversation: showConversation
        ).environmentObject(model)

        if let window {
            window.contentViewController = NSHostingController(rootView: reviewView)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Review Changes"
        window.isReleasedWhenClosed = false
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentViewController = NSHostingController(rootView: reviewView)
        window.delegate = self
        window.setFrameAutosaveName("NopiloteReviewChangesWindow")
        applyWindowLevel(window: window, pinned: model.isPinned)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func applyWindowLevel(pinned: Bool) {
        guard let window else { return }
        applyWindowLevel(window: window, pinned: pinned)
    }

    private func applyWindowLevel(window: NSWindow, pinned: Bool) {
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.discardProposal()
    }
}

@MainActor
final class GlobalHotKeyController {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in controller.action() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let signature: OSType = 0x4E434F50 // NCOP
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let smokeTest: Bool
    private var panelController: PanelController?
    private var hotKeyController: GlobalHotKeyController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    override init() {
        smokeTest = ProcessInfo.processInfo.arguments.contains("--ui-test")
        if ProcessInfo.processInfo.arguments.contains("--ui-test-access-error") {
            model = AppModel(notes: SmokeTestAccessDeniedService(), ai: SmokeTestAIService(), allowsOfflineProvider: true)
        } else if smokeTest {
            model = AppModel(notes: SmokeTestNotesService(), ai: SmokeTestAIService(), allowsOfflineProvider: true)
        } else {
            model = AppModel()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--keychain-smoke-test") {
            do {
                let store = KeychainStore()
                let account = "smoke-test"
                try store.set("temporary", for: account)
                guard try store.read(for: account) == "temporary" else { throw KeychainError.invalidData }
                store.remove(account)
                print("KEYCHAIN_SMOKE_OK")
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("KEYCHAIN_SMOKE_FAILED: \(error.localizedDescription)\n", stderr)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        let panel = PanelController(model: model)
        panelController = panel
        hotKeyController = GlobalHotKeyController { [weak panel] in panel?.toggle() }
        configureStatusItem()
        panel.showOnDesktop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func togglePanel() { panelController?.toggle() }
    func showPanel() { panelController?.show() }

    func applicationWillTerminate(_ notification: Notification) {
        model.endSession()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Nopilote")
        image?.isTemplate = true
        button.image = image
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.imagePosition = image == nil ? .noImage : .imageOnly
        button.setAccessibilityLabel("Open Nopilote")
        button.toolTip = "Nopilote"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem?.menu = statusMenu()
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            showPanel()
        }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Nopilote", action: #selector(showPanelFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "End session", action: #selector(endSession), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nopilote", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func showPanelFromMenu() { showPanel() }
    @objc private func openSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.center()
            NSApplication.shared.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Nopilote Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 260)
        window.contentViewController = NSHostingController(
            rootView: SettingsView().environmentObject(model)
        )
        window.center()
        settingsWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func endSession() { model.endSession() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
