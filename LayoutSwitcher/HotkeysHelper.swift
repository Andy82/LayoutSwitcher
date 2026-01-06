//
//  HotkeysHelper.swift
//  LayoutSwitcher
//
//  Created by Dima Stadub on 24.05.22.
//

struct EditHotKeys: OptionSet, Hashable {

    let rawValue: Int

    static let UndRedo       = EditHotKeys(rawValue: 1 << 0)
    static let CopyPaste      = EditHotKeys(rawValue: 1 << 1)
    static let Find    = EditHotKeys(rawValue: 1 << 2)
    static let All     = EditHotKeys(rawValue: 1 << 3)
    static let OpenSave       = EditHotKeys(rawValue: 1 << 4)
    static let Print     = EditHotKeys(rawValue: 1 << 5)

}

extension EditHotKeys {
    /// Faster iteration without AnySequence/AnyIterator allocations
    func elementsArray() -> [Self] {
        var result: [Self] = []
        var bits = rawValue
        var mask = 1
        while bits != 0 {
            if (bits & mask) != 0 {
                result.append(Self(rawValue: mask))
                bits &= ~mask
            }
            mask &*= 2
        }
        return result
    }
}

// MARK: - Layout-independent key codes mapping (ANSI virtual key codes)
// These are hardware key positions and do not depend on the current input source.

enum KeyCode: UInt16 {
    case a = 0
    case s = 1
    case d = 2
    case f = 3
    case h = 4
    case g = 5
    case z = 6
    case x = 7
    case c = 8
    case v = 9
    case b = 11
    case q = 12
    case w = 13
    case e = 14
    case r = 15
    case y = 16
    case t = 17
    case o = 31
    case p = 35
}

/// Map EditHotKeys groups to the set of key codes that should trigger them.
let editHotkeysKeyCodes: [EditHotKeys: [UInt16]] = [
    .UndRedo: [KeyCode.z.rawValue, KeyCode.y.rawValue],
    .CopyPaste: [KeyCode.x.rawValue, KeyCode.c.rawValue, KeyCode.v.rawValue],
    .Find: [KeyCode.f.rawValue],
    .All: [KeyCode.a.rawValue],
    .OpenSave: [KeyCode.o.rawValue, KeyCode.s.rawValue],
    .Print: [KeyCode.p.rawValue]
]

/// Convenience: get all key codes for a combined option set
func keyCodes(for options: EditHotKeys) -> Set<UInt16> {
    var set = Set<UInt16>()
    for element in options.elementsArray() {
        if let codes = editHotkeysKeyCodes[element] {
            set.formUnion(codes)
        }
    }
    return set
}
