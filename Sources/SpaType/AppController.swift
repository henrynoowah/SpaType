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
    private let updater = Updater()

    private var statusItem: NSStatusItem!
    private var enabled = true
    private var frontmostBundleID: String?
    private var pendingShow: DispatchWorkItem?
    /// Fires when typing pauses mid-word, so a lone "spa" can be fixed before Enter.
    private var pauseWork: DispatchWorkItem?
    private var pausedSuggestion: Suggestion?
    private let pauseDelay: TimeInterval = 0.35

    // AI second opinion: the keys of the current line (one source), and a counter that makes stale answers drop.
    private var lineStrokes: [KeyStroke] = []
    private var lineSource: SourceDescriptor?
    private var aiWork: DispatchWorkItem?
    private var aiGeneration = 0

    // Double-Shift detection
    private var shiftPressedCleanly = false
    private var lastShiftRelease: TimeInterval = 0
    // Tab (and Enter, per Settings) accepts the suggestion; we also swallow the matching key-up.
    private var swallowedUpKey: UInt16?
    /// Keys held back while a correction runs (their key-ups are swallowed too).
    private var heldKeys: Set<UInt16> = []

    /// Apps where "gibberish" is usually intentional (shells, editors, password managers).
    private let excludedBundlePrefixes = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.jetbrains.",
        "dev.warp.", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "dev.zed.", "com.todesktop.230313mzl4w4u92",
        "com.1password.", "com.agilebits.", "com.bitwarden.",
    ]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        catalog.reload()
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        setUpStatusItem()
        observeSystem()

        monitor.handler = { [weak self] type, event in
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if self?.holdDuringCorrection(type: type, keyCode: keyCode, flags: flags) == true { return true }
            // The tap delivers on the main run loop. Handle each key right here, in order, so that by the
            // time Tab arrives the engine has seen every key typed before it.
            if self?.interceptAcceptKey(type: type, keyCode: keyCode, flags: flags) == true { return true }
            if type != .keyUp { self?.handle(type: type, keyCode: keyCode, flags: flags) }
            return false
        }
        startWhenPermitted(prompt: true)

        if Prefs.aiJudge { AIJudge.prewarm() }
        updater.check()
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in self?.updater.check() }
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

        // .deliverImmediately: AppKit suspends distributed notifications for inactive apps, and a menu bar
        // app is always inactive, so the default (.coalesce) would deliver these late, in batches.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self, selector: #selector(selectedSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately
        )
        distributed.addObserver(
            self, selector: #selector(enabledSourcesChanged),
            name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    /// The user switched by hand (e.g. noticed the gibberish) — our bookkeeping is stale.
    @objc private func selectedSourceChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.corrector.isBusy else { return }
            self.resetAll()
        }
    }

    @objc private func enabledSourcesChanged() {
        DispatchQueue.main.async { [weak self] in
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
        cancelAI()

        if IsSecureEventInputEnabled() || isExcludedApp { resetAll(); return }
        if keyCode == USLayout.delete {
            engine.backspace()
            _ = lineStrokes.popLast()
            if !engine.hasRun, !engine.isLongWord { hidePanel() }
            schedulePause()
            return
        }
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if (keyCode == 36 || keyCode == 76), flags.intersection(shortcutModifiers).isEmpty {
            engine.lineBreak()   // Return / keypad Enter: keep "wrong source" in mind for the next line
            lineStrokes = []
            hidePanel()
            return
        }
        if !flags.intersection(shortcutModifiers).isEmpty || !USLayout.isTextKey(keyCode) {
            resetAll()   // shortcuts, arrows, return, tab, esc …
            return
        }
        guard let current = catalog.current, catalog.sources.count > 1 else { resetAll(); return }

        let stroke = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift))
        if lineSource != current { lineStrokes = [] }
        lineSource = current
        lineStrokes.append(stroke)
        if let suggestion = engine.type(stroke, current: current, alternatives: catalog.sources) {
            if shouldAutoConvert(suggestion) {
                apply(suggestion)   // keys typed from here on are held and replayed after the fix
            } else {
                scheduleShow()
            }
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

    /// A wrong-source run long enough (per Settings) is converted at the word boundary without Tab.
    private func shouldAutoConvert(_ suggestion: Suggestion) -> Bool {
        guard let threshold = Prefs.autoConvert.threshold, suggestion.target.kind != .japaneseRomaji else {
            return false
        }
        return suggestion.replay.filter { !$0.isSpace }.count >= threshold
    }

    /// While a correction is typing, the user's keys would land in the middle of it (and in the old source):
    /// hold them, and the corrector replays them once it's done. Shortcuts pass through.
    private func holdDuringCorrection(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        if type == .keyUp { return heldKeys.remove(keyCode) != nil }
        guard type == .keyDown, corrector.isBusy,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        else { return false }
        heldKeys.insert(keyCode)
        corrector.enqueue(KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift)))
        return true
    }

    /// Called synchronously from the event tap (main thread). Swallows Tab / Enter only while a suggestion is showing.
    private func interceptAcceptKey(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let isEnter = keyCode == 36 || keyCode == 76
        guard keyCode == USLayout.tab || (isEnter && Prefs.enterAccepts) else { return false }
        if type == .keyUp {
            defer { if swallowedUpKey == keyCode { swallowedUpKey = nil } }
            return swallowedUpKey == keyCode
        }
        // No modifiers: Shift+Enter stays a plain newline in chat apps.
        guard type == .keyDown, enabled, !corrector.isBusy,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              panel.isVisible, let suggestion = acceptableSuggestion()
        else { return false }
        swallowedUpKey = keyCode
        // Capture the suggestion now; apply it after the tap callback returns. Enter is then replayed
        // after the fix (through the corrector's held-key queue), so a chat message goes out corrected.
        DispatchQueue.main.async { [weak self] in
            self?.apply(suggestion)
            if isEnter { self?.corrector.enqueue(KeyStroke(keyCode: keyCode, shift: false)) }
        }
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
        lineStrokes = []
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
        // or when a long first word is being typed without spaces. The short beat lets the app draw the
        // key first, so the caret position we read is current.
        let delay = engine.isHot || engine.isLongWord ? 0.03 : pauseDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.catalog.current else { return }
            guard let suggestion = self.engine.pauseSuggestion(current: current, alternatives: self.catalog.sources) else {
                if !self.engine.hasRun {
                    self.hidePanel()   // the growing word stopped looking wrong
                    self.scheduleAIJudge(current: current)
                }
                return
            }
            self.pausedSuggestion = suggestion
            self.panel.show(suggestion, near: CaretLocator.caretRect())
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The engine found nothing: once typing has really paused, let the on-device model look at the whole line.
    /// It only suggests (panel + Tab/Enter); it never auto-converts.
    private func scheduleAIJudge(current: SourceDescriptor) {
        cancelAI()
        let words = lineStrokes.split(whereSeparator: \.isSpace)
        guard Prefs.aiJudge, current.kind == .layout, lineSource == current,
              words.count >= 2 || lineStrokes.filter({ !$0.isSpace }).count >= 6
        else { return }
        let generation = aiGeneration
        let line = lineStrokes
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let options = self.catalog.sources.filter { $0.language != current.language }
                .map { self.engine.suggestion(for: line, from: current, target: $0) }
            guard let first = options.first else { return }
            let readings = [first.original] + options.map(\.preview)
            Task { @MainActor [weak self] in
                guard let index = await AIJudge.pick(readings), index > 0,
                      let self, self.aiGeneration == generation, !self.corrector.isBusy
                else { return }
                let suggestion = options[index - 1]
                self.pausedSuggestion = suggestion
                self.panel.show(suggestion, near: CaretLocator.caretRect())
            }
        }
        aiWork = work
        // The pause item may have fired after only a beat (long words); the model waits for a real pause.
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseDelay, execute: work)
    }

    private func cancelAI() {
        aiWork?.cancel()
        aiWork = nil
        aiGeneration += 1
    }

    private func hidePanel() {
        cancelAI()
        pendingShow?.cancel()
        pendingShow = nil
        pauseWork?.cancel()
        pauseWork = nil
        pausedSuggestion = nil
        panel.hide()
    }

    private func resetAll() {
        lineStrokes = []
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

        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update: NSMenuItem
        if updater.isInstalling {
            update = NSMenuItem(title: "업데이트 설치 중…", action: nil, keyEquivalent: "")
            update.isEnabled = false
        } else if let release = updater.available {
            update = NSMenuItem(title: "SpaType \(release.version) 설치…", action: #selector(installUpdate), keyEquivalent: "")
        } else {
            update = NSMenuItem(title: "업데이트 확인 (현재 \(updater.currentVersion))", action: #selector(checkForUpdate), keyEquivalent: "")
        }
        update.target = self
        menu.addItem(update)

        let quit = NSMenuItem(title: "SpaType 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        resetAll()
        updateStatusTitle()
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func checkForUpdate() {
        updater.check { [weak self] release in
            if release != nil {
                self?.installUpdate()
            } else {
                Self.alert("최신 버전이에요", "SpaType \(self?.updater.currentVersion ?? "") 을(를) 쓰고 있어요.")
            }
        }
    }

    @objc private func installUpdate() {
        guard let release = updater.available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "SpaType \(release.version) 설치"
        confirm.informativeText = "새 버전을 받아 설치하고 다시 실행해요."
        confirm.addButton(withTitle: "설치")
        confirm.addButton(withTitle: "릴리즈 노트 보기")
        confirm.addButton(withTitle: "취소")
        switch confirm.runModal() {
        case .alertFirstButtonReturn:
            updater.install(release) { error in
                if Self.alert("업데이트하지 못했어요", error.localizedDescription, extra: "릴리즈 페이지 열기") {
                    NSWorkspace.shared.open(release.pageURL)
                }
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    /// Returns true if the extra button was clicked.
    @discardableResult
    private static func alert(_ title: String, _ text: String, extra: String? = nil) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        if let extra { alert.addButton(withTitle: extra) }
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
