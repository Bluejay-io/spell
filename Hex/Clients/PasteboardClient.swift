//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sauce
import SwiftUI

private let pasteboardLogger = HexLog.pasteboard

enum PasteResult: Equatable, Sendable {
    case pasted
    case copiedToClipboardFallback
}

@DependencyClient
struct PasteboardClient {
    var paste: @Sendable (String) async -> PasteResult = { _ in .copiedToClipboardFallback }
    var copy: @Sendable (String) async -> Void
    var sendKeyboardCommand: @Sendable (KeyboardCommand) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text in
                await live.paste(text: text)
            },
            copy: { text in
                await live.copy(text: text)
            },
            sendKeyboardCommand: { command in
                await live.sendKeyboardCommand(command)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    @Shared(.hexSettings) var hexSettings: HexSettings
    
    private struct PasteboardSnapshot {
        let items: [[String: Any]]
        
        init(pasteboard: NSPasteboard) {
            var saved: [[String: Any]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var itemDict: [String: Any] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemDict[type.rawValue] = data
                    }
                }
                saved.append(itemDict)
            }
            self.items = saved
        }
        
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            for itemDict in items {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    if let data = data as? Data {
                        item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                    }
                }
                pasteboard.writeObjects([item])
            }
        }
    }

    @MainActor
    func paste(text: String) async -> PasteResult {
        if hexSettings.useClipboardPaste {
            return await pasteWithClipboard(text)
        } else {
            return typeDirectly(text) ? .pasted : .copiedToClipboardFallback
        }
    }
    
    @MainActor
    func copy(text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    @MainActor
    func sendKeyboardCommand(_ command: KeyboardCommand) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // Convert modifiers to CGEventFlags and key codes for modifier keys
        var modifierKeyCodes: [CGKeyCode] = []
        var flags = CGEventFlags()
        
        for modifier in command.modifiers.sorted {
            switch modifier.kind {
            case .command:
                flags.insert(.maskCommand)
                modifierKeyCodes.append(55) // Left Cmd
            case .shift:
                flags.insert(.maskShift)
                modifierKeyCodes.append(56) // Left Shift
            case .option:
                flags.insert(.maskAlternate)
                modifierKeyCodes.append(58) // Left Option
            case .control:
                flags.insert(.maskControl)
                modifierKeyCodes.append(59) // Left Control
            case .fn:
                flags.insert(.maskSecondaryFn)
                // Fn key doesn't need explicit key down/up
            }
        }
        
        // Press modifiers down
        for keyCode in modifierKeyCodes {
            let modDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            modDown?.post(tap: .cghidEventTap)
        }
        
        // Press main key if present
        if let key = command.key {
            let keyCode = Sauce.shared.keyCode(for: key)
            
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            keyDown?.flags = flags
            keyDown?.post(tap: .cghidEventTap)
            
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
        }
        
        // Release modifiers in reverse order
        for keyCode in modifierKeyCodes.reversed() {
            let modUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            modUp?.post(tap: .cghidEventTap)
        }
        
        pasteboardLogger.debug("Sent keyboard command: \(command.displayName)")
    }

    @MainActor
    func pasteWithClipboard(_ text: String) async -> PasteResult {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let targetChangeCount = writeAndTrackChangeCount(pasteboard: pasteboard, text: text)
        _ = await waitForPasteboardCommit(targetChangeCount: targetChangeCount)

        let textTargetStatus = Self.focusedTextTargetStatus()
        let pasteSucceeded = await performPaste(text, textTargetStatus: textTargetStatus)
        
        // Only restore original pasteboard contents if:
        // 1. Copying to clipboard is disabled AND
        // 2. The paste operation succeeded
        if !hexSettings.copyToClipboard && pasteSucceeded {
            let savedSnapshot = snapshot
            Task { @MainActor in
                // Give slower apps a short window to read the plain-text entry
                // before we repopulate the clipboard with the user's previous rich data.
                try? await Task.sleep(for: .milliseconds(500))
                pasteboard.clearContents()
                savedSnapshot.restore(to: pasteboard)
            }
        }
        
        // If we failed to paste AND user doesn't want clipboard retention,
        // show a notification that text is available in clipboard
        if !pasteSucceeded && !hexSettings.copyToClipboard {
            // Keep the transcribed text in clipboard regardless of setting
            pasteboardLogger.notice("Paste operation failed; text remains in clipboard as fallback.")
            
            // TODO: Could add a notification here to inform user
            // that text is available in clipboard
        }

        return pasteSucceeded ? .pasted : .copiedToClipboardFallback
    }

    @MainActor
    private func writeAndTrackChangeCount(pasteboard: NSPasteboard, text: String) -> Int {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        if after == before {
            // Ensure we always advance by at least one to avoid infinite waits if the system
            // coalesces writes (seen on Sonoma betas with zero-length strings).
            return after + 1
        }
        return after
    }

    @MainActor
    private func waitForPasteboardCommit(
        targetChangeCount: Int,
        timeout: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(5)
    ) async -> Bool {
        guard targetChangeCount > NSPasteboard.general.changeCount else { return true }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount >= targetChangeCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    // MARK: - Paste Orchestration

    @MainActor
    private enum PasteStrategy {
        case accessibility
        case cmdV
    }

    @MainActor
    private func performPaste(_ text: String, textTargetStatus: FocusedTextTargetStatus) async -> Bool {
        for strategy in strategies(for: textTargetStatus) {
            if await attemptPaste(text, using: strategy) {
                return true
            }
        }
        return false
    }

    private func strategies(for textTargetStatus: FocusedTextTargetStatus) -> [PasteStrategy] {
        switch textTargetStatus {
        case .available:
            return [.accessibility, .cmdV]
        case .unknown, .unavailable:
            return [.cmdV]
        }
    }

    @MainActor
    private func attemptPaste(_ text: String, using strategy: PasteStrategy) async -> Bool {
        switch strategy {
        case .cmdV:
            return await postCmdV(delayMs: 0)
        case .accessibility:
            return (try? Self.insertTextAtCursor(text)) != nil
        }
    }

    // MARK: - Helpers

    @MainActor
    private func postCmdV(delayMs: Int) async -> Bool {
        // Optional tiny wait before keystrokes
        try? await wait(milliseconds: delayMs)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = vKeyCode()
        let cmdKey: CGKeyCode = 55
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private func vKeyCode() -> CGKeyCode {
        if Thread.isMainThread { return Sauce.shared.keyCode(for: .v) }
        return DispatchQueue.main.sync { Sauce.shared.keyCode(for: .v) }
    }

    @MainActor
    private func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    
    func typeDirectly(_ text: String) -> Bool {
        let textTargetStatus = Self.focusedTextTargetStatus()
        guard textTargetStatus != .unavailable else {
            pasteboardLogger.notice("Typing skipped because no focused text input was detected.")
            return false
        }

        do {
            try Self.insertTextAtCursor(text)
            return true
        } catch {
            pasteboardLogger.notice("Direct typing failed; text remains in clipboard fallback. \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    enum PasteError: Error {
        case systemWideElementCreationFailed
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }
    
    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()
        
        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        guard axError == .success, let focusedElementRef = focusedElementRef else {
            throw PasteError.focusedElementNotFound
        }
        
        let focusedElement = focusedElementRef as! AXUIElement
        
        // Verify if the focused element supports text insertion
        var value: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success
        
        if !supportsText && !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }

        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        
        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }

    private enum FocusedTextTargetStatus {
        case available
        case unavailable
        case unknown
    }

    private static func focusedTextTargetStatus() -> FocusedTextTargetStatus {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) else {
            pasteboardLogger.notice("Focused text target status unknown because Accessibility permission is not granted.")
            return .unknown
        }

        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard axError == .success, let focusedElementRef else {
            pasteboardLogger.debug("Focused text target unavailable: AX focused element lookup failed with \(String(describing: axError), privacy: .public)")
            return .unavailable
        }

        let focusedElement = focusedElementRef as! AXUIElement

        var role: String?
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRef) == .success,
           let roleValue = roleRef as? String {
            role = roleValue
            if textInputRoles.contains(roleValue) {
                return .available
            }
        }

        var subrole: String?
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subroleValue = subroleRef as? String {
            subrole = subroleValue
            if textInputSubroles.contains(subroleValue) {
                return .available
            }
        }

        var isSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue {
            return .available
        }

        isSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue {
            return .available
        }

        guard let role else {
            pasteboardLogger.debug("Focused text target unavailable: focused element has no AX role")
            return .unavailable
        }

        pasteboardLogger.debug(
            "Focused element does not look editable role=\(role, privacy: .public) subrole=\(subrole ?? "nil", privacy: .public)"
        )
        return .unavailable
    }

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String
    ]

    private static let textInputSubroles: Set<String> = [
        "AXSearchField"
    ]
}
