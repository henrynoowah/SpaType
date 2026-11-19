import AppKit
import ApplicationServices
import Carbon
import SpaTypeCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let catalog = InputSourceCatalog()
    private lazy var engine = Engine(layoutRenderer: catalog, judge: SpellJudge())
    private let monitor = KeyMonitor()
    private let panel = SuggestionPanel()
    private let corrector = Corrector()

    private var statusItem: NSStatusItem!
    private var enabled = true
    private var frontmostBundleID: String?
    private var pendingShow: DispatchWorkItem?
    /// Fires when typing pauses mid-word, so a lone "spa" can be fixed before Enter.
    private var pauseWork: DispatchWorkItem?
    private var pausedSuggestion: Suggestion?
    private let pauseDelay: TimeInterval = 0.35

    // Double-Shift detection
    private var shiftPressedCleanly = false
    private var lastShiftRelease: TimeInterval = 0
    // Tab accepts the suggestion; we also swallow its matching key-up.
    private var swallowingTabUp = false

    /// Apps where "gibberish" is usually intentional (shells, editors, password managers).
    private let excludedBundlePrefixes = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.jetbrains.",
        "dev.warp.", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "dev.zed.", "com.todesktop.230313mzl4w4u92",
        "com.1password.", "com.agilebits.", "com.bitwarden.",
    ]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        catalog.reload()
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        setUpStatusItem()
        observeSystem()

        monitor.handler = { [weak self] type, event in
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            // The tap delivers on the main run loop. Handle each key right here, in order, so that by the
            // time Tab arrives the engine has seen every key typed before it.
            if self?.interceptAcceptKey(type: type, keyCode: keyCode, flags: flags) == true { return true }
            if type != .keyUp { self?.handle(type: type, keyCode: keyCode, flags: flags) }
            return false
        }
        startWhenPermitted(prompt: true)
    }

    private func startWhenPermitted(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if prompt, !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if trusted, monitor.start() {
            updateStatusTitle()
            return
        }
        updateStatusTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startWhenPermitted(prompt: false)
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.frontmostBundleID = app?.bundleIdentifier
            if let pid = app?.processIdentifier { CaretLocator.enableAccessibility(for: pid) }
            self.resetAll()
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The user switched by hand (e.g. noticed the gibberish) — our bookkeeping is stale.
            guard let self, !self.corrector.isBusy else { return }
            self.resetAll()
        }
        distributed.addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.catalog.reload()
            self?.resetAll()
        }
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        guard enabled, !corrector.isBusy else { return }
        switch type {
        case .keyDown: handleKeyDown(keyCode, flags)
        case .flagsChanged: handleFlagsChanged(keyCode, flags)
        default: resetAll()   // mouse click: caret probably moved
        }
    }

    private func handleKeyDown(_ keyCode: UInt16, _ flags: CGEventFlags) {
        shiftPressedCleanly = false
        lastShiftRelease = 0
        pauseWork?.cancel()
        pausedSuggestion = nil

        if IsSecureEventInputEnabled() || isExcludedApp { resetAll(); return }
        if keyCode == USLayout.delete {
            engine.backspace()
            if !engine.hasRun, !engine.isLongWord { hidePanel() }
            schedulePause()
            return
        }
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if (keyCode == 36 || keyCode == 76), flags.intersection(shortcutModifiers).isEmpty {
            engine.lineBreak()   // Return / keypad Enter: keep "wrong source" in mind for the next line
            hidePanel()
            return
        }
        if !flags.intersection(shortcutModifiers).isEmpty || !USLayout.isTextKey(keyCode) {
            resetAll()   // shortcuts, arrows, return, tab, esc …
            return
        }
        guard let current = catalog.current, catalog.sources.count > 1 else { resetAll(); return }

        let stroke = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift))
        if engine.type(stroke, current: current, alternatives: catalog.sources) != nil {
            scheduleShow()
        } else {
            if !engine.hasRun, !engine.isLongWord { hidePanel() }
            // Mid-word inside a run (or a long word) the panel stays up; either way, re-judge.
            schedulePause()
        }
    }

    private func handleFlagsChanged(_ keyCode: UInt16, _ flags: CGEventFlags) {
        let isShift = keyCode == 56 || keyCode == 60
        guard isShift else { shiftPressedCleanly = false; return }

        if flags.contains(.maskShift) {
            shiftPressedCleanly = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        } else if shiftPressedCleanly {
            shiftPressedCleanly = false
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftRelease < 0.4 {
                lastShiftRelease = 0
                acceptSuggestion()
            } else {
                lastShiftRelease = now
            }
        }
    }

    /// Called synchronously from the event tap (main thread). Swallows Tab only while a suggestion is showing.
    private func interceptAcceptKey(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard keyCode == USLayout.tab else { return false }
        if type == .keyUp {
            defer { swallowingTabUp = false }
            return swallowingTabUp
        }
        guard type == .keyDown, enabled, !corrector.isBusy,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              panel.isVisible, let suggestion = acceptableSuggestion()
        else { return false }
        swallowingTabUp = true
        // Capture the suggestion now; apply it after the tap callback returns.
        DispatchQueue.main.async { [weak self] in self?.apply(suggestion) }
        return true
    }

    private func acceptSuggestion() {
        guard panel.isVisible, let suggestion = acceptableSuggestion() else { return }
        apply(suggestion)
    }

    private func apply(_ suggestion: Suggestion) {
        guard !corrector.isBusy else { return }
        hidePanel()
        engine.reset()
        corrector.apply(suggestion, catalog: catalog) { [weak self] in
            self?.engine.reset()
        }
    }

    /// What accepting would do right now, computed from the engine's current state (not from what the
    /// panel happened to show last), so a just-typed key is never left out or left behind.
    private func acceptableSuggestion() -> Suggestion? {
        if let run = engine.currentSuggestion(includingCurrentWord: true) { return run }
        if let current = catalog.current,
           let live = engine.pauseSuggestion(current: current, alternatives: catalog.sources) {
            return live
        }
        return pausedSuggestion
    }

    private var isExcludedApp: Bool {
        guard let id = frontmostBundleID else { return false }
        return excludedBundlePrefixes.contains { id.hasPrefix($0) }
    }

    // MARK: - Panel

    private func scheduleShow() {
        pendingShow?.cancel()
        // Wait a beat so the app has drawn the space and the caret position is current.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.engine.currentWord.isEmpty,
                  let suggestion = self.engine.currentSuggestion() else { return }
            self.panel.show(suggestion, near: CaretLocator.caretRect())
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func schedulePause() {
        pauseWork?.cancel()
        // Follow every keystroke instead of waiting once we know the user is in the wrong source,
        // or when a long first word is being typed without spaces.
        let delay = engine.isHot || engine.isLongWord ? 0.0 : pauseDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.catalog.current else { return }
            guard let suggestion = self.engine.pauseSuggestion(current: current, alternatives: self.catalog.sources) else {
                if !self.engine.hasRun { self.hidePanel() }   // the growing word stopped looking wrong
                return
            }
            self.pausedSuggestion = suggestion
            self.panel.show(suggestion, near: CaretLocator.caretRect())
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hidePanel() {
        pendingShow?.cancel()
        pendingShow = nil
        pauseWork?.cancel()
        pauseWork = nil
        pausedSuggestion = nil
        panel.hide()
    }

    private func resetAll() {
        engine.reset()
        hidePanel()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = MenuBarIcon.make()
        updateStatusTitle()
    }

    /// Dims the menu bar icon while detection is paused or permissions are missing.
    private func updateStatusTitle() {
        let active = enabled && monitor.isRunning
        statusItem?.button?.appearsDisabled = !active
        statusItem?.button?.toolTip = active ? "SpaType" : "SpaType (일시정지 또는 권한 필요)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(title: enabled ? "감지 일시정지" : "감지 다시 시작", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "감지하는 입력 소스", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for source in catalog.sources {
            let item = NSMenuItem(title: "   \(source.displayName)  (\(source.language))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if catalog.sources.count < 2 {
            let warn = NSMenuItem(title: "   지원되는 입력 소스가 2개 이상 필요해요", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        if !AXIsProcessTrusted() || !monitor.isRunning {
            let permission = NSMenuItem(title: "손쉬운 사용 권한 필요 — 설정 열기…", action: #selector(openPrivacySettings), keyEquivalent: "")
            permission.target = self
            menu.addItem(permission)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "SpaType 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        resetAll()
        updateStatusTitle()
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
