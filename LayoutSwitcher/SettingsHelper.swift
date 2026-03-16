import Foundation

final class SettingsHelper {

    static let shared = SettingsHelper()
    private init() {}

    private let store = UserDefaults.standard

    private enum Key {
        static let hotKeyIndex   = "INDEX_HOT_KEY"
        static let autostart     = "ENABLE_AUTOSTART"
        static let enabled       = "ENABLE"
        static let winEditHotKeys = "WIN_EDIT_HOTKEYS"
    }

    var isAutostartEnabled: Bool {
        get { store.object(forKey: Key.autostart) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.autostart) }
    }

    var isEnabled: Bool {
        get { store.object(forKey: Key.enabled) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.enabled) }
    }

    var winEditKeys: Int {
        get { store.object(forKey: Key.winEditHotKeys) as? Int ?? 0 }
        set { store.set(newValue, forKey: Key.winEditHotKeys) }
    }

    var checkedHotKeyIndex: Int {
        get { store.object(forKey: Key.hotKeyIndex) as? Int ?? 2 }
        set { store.set(newValue, forKey: Key.hotKeyIndex) }
    }
}
