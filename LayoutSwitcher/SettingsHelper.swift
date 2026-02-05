import Foundation
import AppKit

class SettingsHelper {
    private let indexHotKey = "INDEX_HOT_KEY"
    private let enableAutostart = "ENABLE_AUTOSTART"
    private let enable = "ENABLE"
    private let winEditHotKeys = "WIN_EDIT_HOTKEYS"
    private let overlayPositionPrefix = "OVERLAY_POSITION_"
    private let overlayShowOnAllScreensKey = "OVERLAY_SHOW_ON_ALL_SCREENS"
    private let overlayEnabledKey = "OVERLAY_ENABLED"

    static let shared = SettingsHelper()

    private let store = UserDefaults.standard

    var isAutostartEnable: Bool {
        get { store.object(forKey: enableAutostart) as? Bool ?? false }
        set { store.set(newValue, forKey: enableAutostart) }
    }
    
    var isEnable: Bool {
        get { store.object(forKey: enable) as? Bool ?? false }
        set { store.set(newValue, forKey: enable) }
    }
    
    var winEditKeys: Int {
        get { store.object(forKey: winEditHotKeys) as? Int ?? 0 }
        set { store.set(newValue, forKey: winEditHotKeys) }
    }
    
    var checkedHotKeyIndex: Int {
        get { store.object(forKey: indexHotKey) as? Int ?? 2 }
        set { store.set(newValue, forKey: indexHotKey) }
    }

    func overlayPosition(forScreenID screenID: String) -> NSPoint? {
        if let dict = store.dictionary(forKey: overlayPositionPrefix + screenID),
           let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat {
            return NSPoint(x: x, y: y)
        }
        return nil
    }
    
    func setOverlayPosition(_ point: NSPoint, forScreenID screenID: String) {
        let dict: [String: CGFloat] = ["x": point.x, "y": point.y]
        store.set(dict, forKey: overlayPositionPrefix + screenID)
    }

    var overlayShowOnAllScreens: Bool {
        get { store.object(forKey: overlayShowOnAllScreensKey) as? Bool ?? false }
        set { store.set(newValue, forKey: overlayShowOnAllScreensKey) }
    }
    
    var overlayEnabled: Bool {
        get { store.object(forKey: overlayEnabledKey) as? Bool ?? true }
        set { store.set(newValue, forKey: overlayEnabledKey) }
    }
}
