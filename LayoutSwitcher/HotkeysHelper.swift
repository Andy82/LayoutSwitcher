//
//  HotkeysHelper.swift
//  LayoutSwitcher
//
//  Created by Dima Stadub on 24.05.22.
//

import Foundation

struct EditHotKeys: OptionSet, Hashable {

    let rawValue: Int

    static let UndRedo       = EditHotKeys(rawValue: 1 << 0)
    static let CopyPaste      = EditHotKeys(rawValue: 1 << 1)
    static let Find    = EditHotKeys(rawValue: 1 << 2)
    static let All     = EditHotKeys(rawValue: 1 << 3)
    static let OpenSave       = EditHotKeys(rawValue: 1 << 4)
    static let Print     = EditHotKeys(rawValue: 1 << 5)

    func elements() -> AnySequence<Self> {
        var remainingBits = rawValue
        var bitMask: RawValue = 1
        return AnySequence {
            return AnyIterator {
                while remainingBits != 0 {
                    defer { bitMask = bitMask &* 2 }
                    if remainingBits & bitMask != 0 {
                        remainingBits = remainingBits & ~bitMask
                        return Self(rawValue: bitMask)
                    }
                }
                return nil
            }
        }
    }
}

var editHotkeysValues = [
    // Добавлены русские эквиваленты для работы при включённой русской раскладке (ЙЦУКЕН)
    EditHotKeys.UndRedo.rawValue: ["z","y","я","н"],
    EditHotKeys.CopyPaste.rawValue: ["x","c","v","ч","с","м"],
    EditHotKeys.Find.rawValue: ["f","а"],
    EditHotKeys.All.rawValue: ["a","ф"],
    EditHotKeys.OpenSave.rawValue: ["o", "s","щ","ы"],
    EditHotKeys.Print.rawValue: ["p","з"]
]


// Упрощённая карта соответствий только для используемых хоткеев
let ruToEnHotkeyMap: [Character: Character] = [
    "я":"z", // Z
    "н":"y", // Y
    "ч":"x", // X
    "с":"c", // C
    "м":"v", // V
    "ф":"a", // A
    "а":"f", // F
    "щ":"o", // O
    "ы":"s", // S
    "з":"p"  // P
]
/// Нормализация символа хоткея к латинскому эквиваленту (или возврат самого символа, если уже латиница)
func normalizeHotkeyCharacter(_ char: Character) -> Character {
    let lower = String(char).lowercased().first ?? char
    return ruToEnHotkeyMap[lower] ?? lower
}

/// Нормализация строки хоткея (берётся первый символ)
func normalizeHotkeyString(_ s: String) -> String {
    guard let first = s.first else { return s.lowercased() }
    return String(normalizeHotkeyCharacter(first))
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
    for element in options.elements() {
        if let codes = editHotkeysKeyCodes[element] {
            set.formUnion(codes)
        }
    }
    return set
}

