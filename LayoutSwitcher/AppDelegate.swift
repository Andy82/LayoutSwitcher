import AppKit
import ServiceManagement
import Carbon

// CGEventTap callback must not capture context; pass AppDelegate via refcon
private func editEventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    return autoreleasepool { () -> Unmanaged<CGEvent>? in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable tap if the system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = appDelegate.editEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if flags.contains(.maskControl), appDelegate.enabledKeyCodeSet.contains(keyCode) {
            // Synthesize Cmd+key down and up, and suppress original Ctrl+key
            if let src = appDelegate.eventSource {
                if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
                    down.flags = CGEventFlags.maskCommand
                    down.post(tap: CGEventTapLocation.cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                    up.flags = CGEventFlags.maskCommand
                    up.post(tap: CGEventTapLocation.cghidEventTap)
                }
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private var arrayLangHotKeys: [NSEvent.ModifierFlags] = [.function, .option, .control, .command]

    private var menuBarItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var langEventMonitor: Any?
    fileprivate var editEventTap: CFMachPort?
    private var editEventRunLoopSource: CFRunLoopSource?
    fileprivate var enabledKeyCodeSet: Set<CGKeyCode> = []
    
    fileprivate let eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)
    
    private var editKeysState: EditHotKeys = []
    private var modifiersPressed = false

    private struct Constants {
        // Icon image sixe
        static let imageSize = 18.0
        // Key code for a space bar
        static var spaceKeyCode: CGKeyCode = 0x31
    }

    public func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Init application menu and icon
        initMenu()
        
        NSApp.setActivationPolicy(.accessory)
        
        // Check security access to init event monitor
        if isApplicationHasSecurityAccess() {
            if SettingsHelper.shared.isEnable {
                initLanSwitchEventMonitor()
                initWinEditEventMonitor()
            }
        } else {
            let securityAlert = NSAlert()
            
            securityAlert.messageText = "Need security permissions"
            securityAlert.informativeText = "Please provide security permissions for the application and restart it.\nThis is needed to be able globally monitor shortcuts to switch keyboard layout."
            securityAlert.alertStyle = .critical
            securityAlert.addButton(withTitle: "Settings")
            securityAlert.addButton(withTitle: "Exit")
            
            if securityAlert.runModal() == .alertFirstButtonReturn {
                openPrivacySettings()
            }
            
            // Shutdown the application anyway
            exit(-1)
        }
    }

    public func applicationWillTerminate(_ aNotification: Notification) {
        clearInputSourcesCache()
        deinitLangEventMonitor()
        deinitEditEventMonitor()
    }
    
    private func updateEditMenuState(editkeysMenu: NSMenuItem){
        let submenu = editkeysMenu.submenu
        var hotkeysState: NSControl.StateValue = .off
        submenu?.items.forEach {
            if( $0.isSeparatorItem || hotkeysState == .mixed ){
                return
            }
                
            switch $0.state{
            case .on:
                hotkeysState = .on
            case .off:
                if(hotkeysState == .on ){
                    hotkeysState = .mixed
                }
            default:
                return
            }
        }
        
        editkeysMenu.state = hotkeysState
    }
    
    private func newEditMenuItem(_ title: String, key: String, tag:EditHotKeys) -> NSMenuItem {
        let menuItem = NSMenuItem()
        menuItem.title = title
        menuItem.action = #selector(applicationSetWinEditKey)
        menuItem.keyEquivalent = key
        menuItem.tag = tag.rawValue
        menuItem.state = editKeysState.contains(tag) ? .on : .off
        return menuItem
    }
    
    private func initMenu() {
        // Define application's tray icon
        if let menuBarButton = menuBarItem.button {
            menuBarButton.image = #imageLiteral(resourceName: "MenuBarIcon")
            menuBarButton.image?.size = NSSize(width: Constants.imageSize, height: Constants.imageSize)
            menuBarButton.image?.isTemplate = true
            menuBarButton.target = self
        }
        
        // Define hot keys submenu
        let hotkeysSubmenu = NSMenu.init()
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Fn",        action: #selector(applicationChangeHotkey), keyEquivalent: "")
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Option ⌥",  action: #selector(applicationChangeHotkey), keyEquivalent: "")
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Control ⌃", action: #selector(applicationChangeHotkey), keyEquivalent: "")
        hotkeysSubmenu.addItem(withTitle: "Shift ⇧ + Command ⌘", action: #selector(applicationChangeHotkey), keyEquivalent: "")
        
        // Get saved checked hot key from previous start
        hotkeysSubmenu.item(at: SettingsHelper.shared.checkedHotKeyIndex)?.state = .on
        
        // Define main menu
        let statusBarMenu = NSMenu()
        let hotkeysMenu = statusBarMenu.addItem(withTitle: "Layout shortcuts", action: nil, keyEquivalent: "")
        
        // Assign submenu to main menu
        hotkeysMenu.submenu = hotkeysSubmenu
        
        // Define edit hot keys submenu
        let editHotkeysSubmenu = NSMenu.init()
        
        editKeysState = EditHotKeys(rawValue: SettingsHelper.shared.winEditKeys)

        editHotkeysSubmenu.addItem(newEditMenuItem("Undo/Redo: Control ⌃ + Z | Y", key: "z",tag: EditHotKeys.UndRedo))
        editHotkeysSubmenu.addItem(newEditMenuItem("Copy/Paste: Control ⌃ + X | C | V", key: "c",tag: EditHotKeys.CopyPaste))
        editHotkeysSubmenu.addItem(NSMenuItem.separator())
        editHotkeysSubmenu.addItem(newEditMenuItem("Find: Control ^ + F",key: "f", tag: EditHotKeys.Find))
        editHotkeysSubmenu.addItem(newEditMenuItem("Select all: Control ⌃ + A",key: "a", tag: EditHotKeys.All))
        editHotkeysSubmenu.addItem(newEditMenuItem("Open/Save: Control ⌃ + O | S", key: "o",tag: EditHotKeys.OpenSave))
        editHotkeysSubmenu.addItem(NSMenuItem.separator())
        editHotkeysSubmenu.addItem(newEditMenuItem("Print: Control ⌃ + P",key: "p",tag: EditHotKeys.Print))
    
        // Define main menu
        let editkeysMenu = statusBarMenu.addItem(withTitle: "Edit shortcuts", action: nil, keyEquivalent: "")
        
        // Assign submenu to main menu
        editkeysMenu.submenu = editHotkeysSubmenu
        updateEditMenuState(editkeysMenu: editkeysMenu)
        
        // Define autostart menu and get previos state
        let autostartMenuItem = NSMenuItem(title: "Launch at login", action: #selector(applicationAutostart), keyEquivalent: "s")
        autostartMenuItem.state = SettingsHelper.shared.isAutostartEnable ? .on : .off
        statusBarMenu.addItem(autostartMenuItem)
        
        let disableItem = NSMenuItem(title: "Disable app", action: #selector(applicationDisable), keyEquivalent: "")
        disableItem.state = SettingsHelper.shared.isEnable ? .off : .on
        statusBarMenu.addItem(disableItem)
        statusBarMenu.addItem(NSMenuItem.separator())
        
        // Define other menu items
        statusBarMenu.addItem(NSMenuItem.separator())
        statusBarMenu.addItem(withTitle: "About...", action: #selector(applicationAbout), keyEquivalent: "a")
        statusBarMenu.addItem(withTitle: "Quit", action: #selector(applicationQuit), keyEquivalent: "q")
        
        menuBarItem.menu = statusBarMenu
    }
    
    private func initLanSwitchEventMonitor() {
        // Get second modifier key, according to menu
        let secondModifierFlag = arrayLangHotKeys[SettingsHelper.shared.checkedHotKeyIndex]
        
        // Enable key event monitor
        langEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            autoreleasepool {
                guard let self = self else { return }
                let areModifiersActive = event.modifierFlags.contains(.shift) && event.modifierFlags.contains(secondModifierFlag)
                if areModifiersActive {
                    // set Flag when required modifier keys pressed
                    self.modifiersPressed = true
                } else if self.modifiersPressed {
                    // if required modifier keys pressed and Flag is set
                    // run change layout routine (keys released)
                    self.sendDefaultChangeLayoutHotkey()
                    // reset Flag
                    self.modifiersPressed = false
                }
            }
        }
    }
    
    private func initWinEditEventMonitor() {
        // Collect layout-independent key codes for enabled options and store in property for callback access
        let enabledKeyCodes = keyCodes(for: editKeysState).map { CGKeyCode($0) }
        enabledKeyCodeSet = Set(enabledKeyCodes)

        // Create CGEventTap for keyDown and tap disable notifications
        let eventsMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.tapDisabledByTimeout.rawValue) | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        if let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                       place: .headInsertEventTap,
                                       options: .defaultTap,
                                       eventsOfInterest: CGEventMask(eventsMask),
                                       callback: editEventTapCallback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            editEventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            editEventRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // Could not create tap — likely due to missing permissions (Input Monitoring)
            NSLog("Failed to create CGEventTap. Check Accessibility and Input Monitoring permissions.")
            let alert = NSAlert()
            alert.messageText = "Need Input Monitoring permission"
            alert.informativeText = "Please enable LayoutSwitcher in System Settings → Privacy & Security → Input Monitoring and Accessibility, then restart the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    _ = NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func deinitLangEventMonitor() {
        guard langEventMonitor != nil else {return}
        NSEvent.removeMonitor(langEventMonitor!)
        clearInputSourcesCache()
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
    
    private func updateLangEventMonitor() {
        deinitLangEventMonitor()
        initLanSwitchEventMonitor()
    }
    
    private func updateEditEventMonitor() {
        // Recalculate the enabled key codes set
        let newSet = Set(keyCodes(for: editKeysState).map { CGKeyCode($0) })
        if newSet.isEmpty {
            // No keys to intercept — disable tap if present
            enabledKeyCodeSet = []
            deinitEditEventMonitor()
            return
        }
        if editEventTap != nil {
            enabledKeyCodeSet = newSet
        } else {
            enabledKeyCodeSet = newSet
            initWinEditEventMonitor()
        }
    }
    
    private func isApplicationHasSecurityAccess() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        return AXIsProcessTrustedWithOptions(options)
    }
    
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            _ = NSWorkspace.shared.open(url)
        }
    }
    
    // TODO: To add some more combinations for different use-cases
    private func sendDefaultChangeLayoutHotkey() {
        switchToNextKeyboardInputSource()
    }

    // Cache of selectable keyboard input sources
    private lazy var cachedInputSources: [TISInputSource] = {
        var arr: [TISInputSource] = []
        // Do not load here; will be loaded on first use by reloadInputSources()
        return arr
    }()
    
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
        let listAny: NSArray = TISCreateInputSourceList(properties as CFDictionary, false).takeRetainedValue() as NSArray
        var result: [TISInputSource] = []
        result.reserveCapacity(listAny.count)
        for case let src as TISInputSource in listAny {
            result.append(src)
        }
        cachedInputSources = result
    }

    // Switch to the next enabled keyboard input source (avoids relying on system hotkeys like Spotlight)
    private func switchToNextKeyboardInputSource() {
        if cachedInputSources.isEmpty { reloadInputSources() }

        let current: TISInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let currentIDPtr = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return }
        let currentID = unsafeBitCast(currentIDPtr, to: CFString.self) as String

        var nextIndex = 0
        var found = false
        for (i, src) in cachedInputSources.enumerated() {
            if let srcIDPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let srcID = unsafeBitCast(srcIDPtr, to: CFString.self) as String
                if srcID == currentID {
                    nextIndex = (i + 1) % cachedInputSources.count
                    found = true
                    break
                }
            }
        }
        if !found { reloadInputSources() }
        if cachedInputSources.isEmpty { return }
        if !found {
            // Retry once with fresh cache
            for (i, src) in cachedInputSources.enumerated() {
                if let srcIDPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                    let srcID = unsafeBitCast(srcIDPtr, to: CFString.self) as String
                    if srcID == currentID {
                        nextIndex = (i + 1) % cachedInputSources.count
                        break
                    }
                }
            }
        }
        let nextSrc = cachedInputSources[nextIndex]
        TISSelectInputSource(nextSrc)
    }
    
    @objc private func applicationChangeHotkey(_ sender: NSMenuItem) {
        // Update the checked state of menu item and save it
        sender.state = sender.state == .on ? .off : .on
        SettingsHelper.shared.checkedHotKeyIndex = sender.menu!.index(of: sender)
        
        // Restart eventMonitor with new hot key
        self.updateLangEventMonitor()
        
        // Set previosly checked item to unchecked
        sender.menu?.items.forEach {
            if ($0 != sender && $0.state == .on) {
                $0.state = sender.state == .on ? .off : .on
            }
        }        
    }
    
    @objc private func applicationSetWinEditKey(_ sender: NSMenuItem) {
        // Update the checked state of menu item and save it
        sender.state = sender.state == .on ? .off : .on
        
        var tagsValue = 0
        
        sender.menu?.items.forEach {
            if ($0.state == .on) {
                tagsValue += $0.tag
            }
        }
        
        SettingsHelper.shared.winEditKeys = tagsValue
        
        editKeysState = EditHotKeys(rawValue: tagsValue)
        
        // Restart eventMonitor with new hot key
        self.updateEditMenuState(editkeysMenu: sender.parent!)
        self.updateEditEventMonitor()

    }
    
    @objc private func applicationDisable(_ sender: NSMenuItem) {
        // Update menu item checkbox
        sender.state = sender.state == .on ? .off : .on
        
        // Get the new state based on the menu item checkbox
        let disabled = sender.state == .on ? true : false
        
        SettingsHelper.shared.isEnable = !disabled
        
        if (disabled){
            deinitLangEventMonitor()
            deinitEditEventMonitor()
            clearInputSourcesCache()
        }
        else{
            updateLangEventMonitor()
            updateEditEventMonitor()
        }
    }
    
    private func launchAtLogin(_ newState: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if newState {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                return false
            }
        } else {
            // No separate launcher/helper used; not supported on older macOS
            return false
        }
    }
    
    @objc private func applicationAutostart(_ sender: NSMenuItem) {
        // Update menu item checkbox
        sender.state = sender.state == .on ? .off : .on
        
        // Get the new state based on the menu item checkbox
        let newState = sender.state == .on ? true : false

        // Run helping application to enable autostart
        let setupResult = launchAtLogin(newState)
        
        // Save settings if action takes effect
        if setupResult == true {
            SettingsHelper.shared.isAutostartEnable = newState
        } else {
            let securityAlert = NSAlert()
            
            securityAlert.messageText = "Can't perform this operation"
            securityAlert.informativeText = "Please check that application was copied to /Application directory and try again.\nYou can also add it manually Settings -> Users and Groups -> Login Items"
            securityAlert.alertStyle = .warning
            securityAlert.addButton(withTitle: "Ok")
        }
    }
    
    @objc private func applicationAbout() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let aboutAlert = NSAlert()
        
        aboutAlert.messageText = "Layout Switcher v." + appVersion!
        aboutAlert.informativeText = "LayoutSwitcher is open-source application that allows you to change keyboard layout using shortcuts that are not alloved by MacOS: Fn + Shift ⇧, Option ⌥ + Shift ⇧, Command ⌘ + Shift ⇧ or Control ⌃ + Shift ⇧. \nIn some sence it an alternative for the Punto Switcher or Karabiner if you are using it for similar purpose, because both are kind of overkill for this."
        aboutAlert.alertStyle = .informational
        aboutAlert.addButton(withTitle: "Ok")
        aboutAlert.runModal()
    }

    @objc private func applicationQuit() {
        exit(0)
    }
}
