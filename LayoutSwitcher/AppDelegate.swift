import AppKit
import ServiceManagement
import Carbon

// CGEventTap callback — must be a top-level C function; AppDelegate is passed via refcon
private func editEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    return autoreleasepool { () -> Unmanaged<CGEvent>? in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable tap if the system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = app.editEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Control+Command+<key> → Command+<key>
        if flags.contains(.maskControl) && flags.contains(.maskCommand),
           app.enabledKeyCodeSet.contains(keyCode) {
            postKey(keyCode, flags: .maskCommand, source: app.eventSource)
            return nil
        }

        // Fn+Z → Control+Z (unless ignoreFnSubstitution is active for this key)
        if flags.contains(.maskSecondaryFn) {
            if app.ignoreFnSubstitutionForEditCombos && app.enabledKeyCodeSet.contains(keyCode) {
                return Unmanaged.passUnretained(event)
            }
            if keyCode == KeyCode.z.rawValue && !flags.contains(.maskControl) {
                guard !app.isFrontmostAppDisabled else { return Unmanaged.passUnretained(event) }
                postKey(keyCode, flags: .maskControl, source: app.eventSource)
                return nil
            }
        }

        // Control+<key> → Command+<key>
        if flags.contains(.maskControl), app.enabledKeyCodeSet.contains(keyCode) {
            guard !app.isFrontmostAppDisabled else { return Unmanaged.passUnretained(event) }
            postKey(keyCode, flags: .maskCommand, source: app.eventSource)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
    guard let src = source else { return }
    if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
        down.flags = flags
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let langHotKeys: [NSEvent.ModifierFlags] = [.function, .option, .control, .command]

    private var menuBarItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var langEventMonitor: Any?
    fileprivate var editEventTap: CFMachPort?
    private var editEventRunLoopSource: CFRunLoopSource?
    fileprivate var enabledKeyCodeSet: Set<CGKeyCode> = []

    fileprivate let eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)

    private var editKeysState: EditHotKeys = []
    private var modifiersPressed = false

    fileprivate var ignoreFnSubstitutionForEditCombos: Bool {
        get { UserDefaults.standard.bool(forKey: "IgnoreFnSubstitutionForEditCombos") }
        set { UserDefaults.standard.set(newValue, forKey: "IgnoreFnSubstitutionForEditCombos") }
    }

    // Cached in memory — avoids UserDefaults reads in the CGEventTap hot path
    fileprivate private(set) var disabledBundleIDs: Set<String> = []

    // Cached frontmost app state — updated via NSWorkspace notification, not per-keypress
    fileprivate var isFrontmostAppDisabled: Bool = false
    private var appActivationObserver: Any?

    private enum Constants {
        static let imageSize: CGFloat = 18
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        loadDisabledBundleIDs()
        initMenu()
        NSApp.setActivationPolicy(.accessory)

        // Cache current frontmost app and observe future switches
        isFrontmostAppDisabled = checkFrontmost()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.isFrontmostAppDisabled = self?.shouldDisableRemap(for: runningApp?.bundleIdentifier) ?? false
        }

        guard isApplicationHasSecurityAccess() else {
            showSecurityPermissionAlert()
            exit(-1)
        }

        if SettingsHelper.shared.isEnabled {
            initLangSwitchEventMonitor()
            initWinEditEventMonitor()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        clearInputSourcesCache()
        deinitLangEventMonitor()
        deinitEditEventMonitor()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
    }

    // MARK: - Disabled Apps Cache

    private var defaultDisabledBundleIDs: Set<String> {
        [
            "com.microsoft.rdc.macos",
            "com.microsoft.rdc.macos.beta",
            "com.microsoft.rdc",
            "com.lemonmojo.RoyalTSX.App"
        ]
    }

    private func loadDisabledBundleIDs() {
        let saved = UserDefaults.standard.array(forKey: "DisabledBundleIdentifiers") as? [String]
        disabledBundleIDs = (saved.map(Set.init) ?? nil).flatMap { $0.isEmpty ? nil : $0 } ?? defaultDisabledBundleIDs
    }

    private func saveDisabledBundleIDs() {
        UserDefaults.standard.set(Array(disabledBundleIDs), forKey: "DisabledBundleIdentifiers")
    }

    private func checkFrontmost() -> Bool {
        return shouldDisableRemap(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    fileprivate func shouldDisableRemap(for bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return disabledBundleIDs.contains(id)
    }

    // MARK: - Menu

    private func initMenu() {
        if let button = menuBarItem.button {
            button.image = #imageLiteral(resourceName: "MenuBarIcon")
            button.image?.size = NSSize(width: Constants.imageSize, height: Constants.imageSize)
            button.image?.isTemplate = true
        }

        let statusBarMenu = NSMenu()

        // Layout shortcuts submenu
        let hotkeysSubmenu = NSMenu()
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Fn",        action: #selector(changeHotkey), keyEquivalent: "")
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Option ⌥",  action: #selector(changeHotkey), keyEquivalent: "")
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Control ⌃", action: #selector(changeHotkey), keyEquivalent: "")
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Command ⌘", action: #selector(changeHotkey), keyEquivalent: "")
        hotkeysSubmenu.item(at: SettingsHelper.shared.checkedHotKeyIndex)?.state = .on
        let hotkeysMenu = statusBarMenu.addItem(withTitle: "Layout shortcuts", action: nil, keyEquivalent: "")
        hotkeysMenu.submenu = hotkeysSubmenu

        // Edit shortcuts submenu
        editKeysState = EditHotKeys(rawValue: SettingsHelper.shared.winEditKeys)
        let editHotkeysSubmenu = NSMenu()
        editHotkeysSubmenu.addItem(newEditMenuItem("Undo/Redo: Control ⌃ + Z | Y",      key: "z", tag: .UndRedo))
        editHotkeysSubmenu.addItem(newEditMenuItem("Copy/Paste: Control ⌃ + X | C | V", key: "c", tag: .CopyPaste))
        editHotkeysSubmenu.addItem(.separator())
        editHotkeysSubmenu.addItem(newEditMenuItem("Find: Control ⌃ + F",               key: "f", tag: .Find))
        editHotkeysSubmenu.addItem(newEditMenuItem("Select all: Control ⌃ + A",         key: "a", tag: .All))
        editHotkeysSubmenu.addItem(newEditMenuItem("Open/Save: Control ⌃ + O | S",      key: "o", tag: .OpenSave))
        editHotkeysSubmenu.addItem(.separator())
        editHotkeysSubmenu.addItem(newEditMenuItem("Print: Control ⌃ + P",              key: "p", tag: .Print))
        let editkeysMenu = statusBarMenu.addItem(withTitle: "Edit shortcuts", action: nil, keyEquivalent: "")
        editkeysMenu.submenu = editHotkeysSubmenu
        updateEditMenuState(editkeysMenu: editkeysMenu)

        // Launch at login
        let autostartItem = NSMenuItem(title: "Launch at login", action: #selector(toggleAutostart), keyEquivalent: "s")
        autostartItem.state = SettingsHelper.shared.isAutostartEnabled ? .on : .off
        statusBarMenu.addItem(autostartItem)

        statusBarMenu.addItem(.separator())

        // Ctrl→Cmd section
        let remapLabel = NSMenuItem(title: "Remap Ctrl→Cmd (except Disabled for apps)", action: nil, keyEquivalent: "")
        remapLabel.isEnabled = false
        statusBarMenu.addItem(remapLabel)

        let ignoreFnItem = NSMenuItem(title: "Ignore Fn substitution for edit combos", action: #selector(toggleIgnoreFnSubstitution), keyEquivalent: "")
        ignoreFnItem.state = ignoreFnSubstitutionForEditCombos ? .on : .off
        statusBarMenu.addItem(ignoreFnItem)

        let disabledAppsItem = NSMenuItem(title: "Disabled for…", action: nil, keyEquivalent: "")
        disabledAppsItem.submenu = NSMenu()
        statusBarMenu.addItem(disabledAppsItem)

        statusBarMenu.addItem(.separator())

        let disableItem = NSMenuItem(title: "Disable app", action: #selector(toggleDisableApp), keyEquivalent: "")
        disableItem.state = SettingsHelper.shared.isEnabled ? .off : .on
        statusBarMenu.addItem(disableItem)

        statusBarMenu.addItem(.separator())
        statusBarMenu.addItem(withTitle: "About…", action: #selector(showAbout), keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "Quit",   action: #selector(quit),      keyEquivalent: "q")

        menuBarItem.menu = statusBarMenu
        rebuildDisabledAppsMenu()
    }

    private func newEditMenuItem(_ title: String, key: String, tag: EditHotKeys) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        item.action = #selector(setWinEditKey)
        item.keyEquivalent = key
        item.tag = tag.rawValue
        item.state = editKeysState.contains(tag) ? .on : .off
        return item
    }

    private func updateEditMenuState(editkeysMenu: NSMenuItem) {
        guard let submenu = editkeysMenu.submenu else { return }
        var state: NSControl.StateValue = .off
        for item in submenu.items {
            guard !item.isSeparatorItem, state != .mixed else { continue }
            switch item.state {
            case .on:  state = (state == .off) ? .on : state
            case .off: if state == .on { state = .mixed }
            default:   break
            }
        }
        editkeysMenu.state = state
    }

    // MARK: - Menu Actions

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        // Radio-button: select clicked item, deselect all others
        menu.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        SettingsHelper.shared.checkedHotKeyIndex = menu.index(of: sender)
        updateLangEventMonitor()
    }

    @objc private func setWinEditKey(_ sender: NSMenuItem) {
        sender.state = (sender.state == .on) ? .off : .on
        var tagsValue = 0
        sender.menu?.items.forEach { if $0.state == .on { tagsValue += $0.tag } }
        SettingsHelper.shared.winEditKeys = tagsValue
        editKeysState = EditHotKeys(rawValue: tagsValue)
        if let parent = sender.parent { updateEditMenuState(editkeysMenu: parent) }
        updateEditEventMonitor()
    }

    @objc private func toggleDisableApp(_ sender: NSMenuItem) {
        sender.state = (sender.state == .on) ? .off : .on
        let enabled = sender.state == .off
        SettingsHelper.shared.isEnabled = enabled
        if enabled {
            updateLangEventMonitor()
            updateEditEventMonitor()
        } else {
            deinitLangEventMonitor()
            deinitEditEventMonitor()
            clearInputSourcesCache()
        }
    }

    @objc private func toggleAutostart(_ sender: NSMenuItem) {
        let newState = sender.state != .on
        guard launchAtLogin(newState) else {
            let alert = NSAlert()
            alert.messageText = "Can't enable launch at login"
            alert.informativeText = "Please ensure the app is in the /Applications folder, or add it manually in Settings → Users and Groups → Login Items."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        sender.state = newState ? .on : .off
        SettingsHelper.shared.isAutostartEnabled = newState
    }

    @objc private func toggleIgnoreFnSubstitution(_ sender: NSMenuItem) {
        sender.state = (sender.state == .on) ? .off : .on
        ignoreFnSubstitutionForEditCombos = (sender.state == .on)
    }

    @objc private func toggleDisabledApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if sender.state == .on {
            disabledBundleIDs.remove(bundleID)
            sender.state = .off
        } else {
            disabledBundleIDs.insert(bundleID)
            sender.state = .on
        }
        saveDisabledBundleIDs()
        isFrontmostAppDisabled = checkFrontmost()
    }

    @objc private func addDisabledApp(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to disable"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        disabledBundleIDs.insert(bundleID)
        saveDisabledBundleIDs()
        isFrontmostAppDisabled = checkFrontmost()
        rebuildDisabledAppsMenu()
    }

    private func rebuildDisabledAppsMenu() {
        guard let menu = menuBarItem.menu,
              let submenu = menu.item(withTitle: "Disabled for…")?.submenu else { return }
        submenu.removeAllItems()
        for id in disabledBundleIDs.sorted() {
            let item = NSMenuItem(title: id, action: #selector(toggleDisabledApp(_:)), keyEquivalent: "")
            item.state = .on
            item.representedObject = id
            item.target = self
            submenu.addItem(item)
        }
        if !disabledBundleIDs.isEmpty { submenu.addItem(.separator()) }
        let addItem = NSMenuItem(title: "Add App…", action: #selector(addDisabledApp(_:)), keyEquivalent: "")
        addItem.target = self
        submenu.addItem(addItem)
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Layout Switcher v.\(version)"
        alert.informativeText = "Open-source macOS utility for switching keyboard layouts using custom shortcuts (Fn+Shift, Option+Shift, Control+Shift, Command+Shift) and remapping Ctrl→Cmd for Windows-style edit shortcuts."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Security

    private func isApplicationHasSecurityAccess() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    private func showSecurityPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission required"
        alert.informativeText = "Please grant Accessibility permission in System Settings → Privacy & Security → Accessibility, then relaunch the app."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lang Switch Monitor

    private func initLangSwitchEventMonitor() {
        let secondModifier = langHotKeys[SettingsHelper.shared.checkedHotKeyIndex]
        langEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            autoreleasepool {
                guard let self else { return }
                let active = event.modifierFlags.contains(.shift) && event.modifierFlags.contains(secondModifier)
                if active {
                    self.modifiersPressed = true
                } else if self.modifiersPressed {
                    self.switchToNextKeyboardInputSource()
                    self.modifiersPressed = false
                }
            }
        }
    }

    private func deinitLangEventMonitor() {
        guard let monitor = langEventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        langEventMonitor = nil
        clearInputSourcesCache()
    }

    private func updateLangEventMonitor() {
        deinitLangEventMonitor()
        initLangSwitchEventMonitor()
    }

    // MARK: - Edit Remap Monitor

    private func initWinEditEventMonitor() {
        enabledKeyCodeSet = Set(keyCodes(for: editKeysState).map { CGKeyCode($0) })

        let eventsMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsMask,
            callback: editEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Failed to create CGEventTap. Check Accessibility and Input Monitoring permissions.")
            showInputMonitoringAlert()
            return
        }
        editEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        editEventRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func deinitEditEventMonitor() {
        if let source = editEventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            editEventRunLoopSource = nil
        }
        if let tap = editEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            editEventTap = nil
        }
    }

    private func updateEditEventMonitor() {
        enabledKeyCodeSet = Set(keyCodes(for: editKeysState).map { CGKeyCode($0) })
        if enabledKeyCodeSet.isEmpty {
            deinitEditEventMonitor()
        } else if editEventTap == nil {
            initWinEditEventMonitor()
        }
    }

    private func showInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring permission required"
        alert.informativeText = "Please enable LayoutSwitcher in System Settings → Privacy & Security → Input Monitoring, then relaunch the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Launch at Login

    private func launchAtLogin(_ enable: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - Input Sources

    private lazy var cachedInputSources: [TISInputSource] = []

    private func clearInputSourcesCache() {
        cachedInputSources.removeAll(keepingCapacity: false)
    }

    private func reloadInputSources() {
        clearInputSourcesCache()
        let properties: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        let list = TISCreateInputSourceList(properties as CFDictionary, false).takeRetainedValue() as NSArray
        var result = [TISInputSource]()
        result.reserveCapacity(list.count)
        for case let src as TISInputSource in list {
            result.append(src)
        }
        cachedInputSources = result
    }

    private func switchToNextKeyboardInputSource() {
        if cachedInputSources.isEmpty { reloadInputSources() }

        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let currentIDPtr = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return }
        let currentID = unsafeBitCast(currentIDPtr, to: CFString.self) as String

        func findNextIndex(in sources: [TISInputSource]) -> Int? {
            for (i, src) in sources.enumerated() {
                guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
                if unsafeBitCast(ptr, to: CFString.self) as String == currentID {
                    return (i + 1) % sources.count
                }
            }
            return nil
        }

        var nextIndex = findNextIndex(in: cachedInputSources)
        if nextIndex == nil {
            reloadInputSources()
            nextIndex = findNextIndex(in: cachedInputSources)
        }
        guard let idx = nextIndex, !cachedInputSources.isEmpty else { return }
        TISSelectInputSource(cachedInputSources[idx])
    }
}
