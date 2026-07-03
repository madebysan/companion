import AppKit
import HotKey
import Carbon.HIToolbox

// Manages the global keyboard shortcut
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKey: HotKey?

    // Register the global hotkey (default: Cmd+Shift+E)
    func register() {
        let settings = UserSettings.shared

        if let keyCode = settings.shortcutKeyCode,
           let modifiers = settings.shortcutModifiers {
            if let key = Key(carbonKeyCode: keyCode) {
                let mods = carbonToNSModifiers(modifiers)
                hotKey = HotKey(key: key, modifiers: mods)
            }
        }

        // Fall back to default: Cmd+Shift+E
        if hotKey == nil {
            hotKey = HotKey(key: .e, modifiers: [.command, .shift])
        }

        hotKey?.keyDownHandler = { [weak self] in
            self?.handleHotkey()
        }
    }

    // Update the shortcut (called from Settings)
    func updateShortcut(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        hotKey = nil
        if let key = Key(carbonKeyCode: keyCode) {
            hotKey = HotKey(key: key, modifiers: modifiers)
            hotKey?.keyDownHandler = { [weak self] in
                self?.handleHotkey()
            }
        }

        UserSettings.shared.shortcutKeyCode = keyCode
        UserSettings.shared.shortcutModifiers = UInt(modifiers.rawValue)
    }

    // Reset to default shortcut
    func resetToDefault() {
        hotKey = nil
        hotKey = HotKey(key: .e, modifiers: [.command, .shift])
        hotKey?.keyDownHandler = { [weak self] in
            self?.handleHotkey()
        }
        UserSettings.shared.shortcutKeyCode = nil
        UserSettings.shared.shortcutModifiers = nil
    }

    private func handleHotkey() {
        if CommandPaletteWindowController.shared.isPaletteVisible {
            CommandPaletteWindowController.shared.close()
        } else {
            TextGrabber.shared.grabSelectionAndShowPalette()
        }
    }

    private func carbonToNSModifiers(_ carbonMods: UInt) -> NSEvent.ModifierFlags {
        var mods: NSEvent.ModifierFlags = []
        if carbonMods & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 { mods.insert(.command) }
        if carbonMods & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 { mods.insert(.shift) }
        if carbonMods & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 { mods.insert(.option) }
        if carbonMods & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 { mods.insert(.control) }
        return mods
    }
}
