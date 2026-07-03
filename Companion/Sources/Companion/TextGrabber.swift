import AppKit
import Carbon.HIToolbox
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.santiagoalonso.companion", category: "TextGrabber")

// Handles grabbing selected text via clipboard and pasting results back
@MainActor
final class TextGrabber {
    static let shared = TextGrabber()

    // Called when rewrite status changes (for menu bar feedback)
    var onStatusChange: ((RewriteStatus) -> Void)?

    // Prevent overlapping triggers
    private var isProcessing = false
    private var activeSession: RewriteSession?
    private var activeRequestID: UUID?
    private var activeRewriteTask: Task<Void, Never>?
    private var pendingPreview: PendingPreview?
    private var didCopyPendingPreview = false

    private struct RewriteSession {
        let selectedText: String
        let selectedWordCount: Int
        let sourceApp: NSRunningApplication?
        let savedItems: [NSPasteboardItem]
    }

    private struct FocusedTextContext {
        let selectedText: String
        let caretRect: CGRect?
    }

    private struct PendingPreview {
        let result: String
        let session: RewriteSession
        let images: [PromptImageAttachment]
    }

    private enum PastePresentation {
        case status
        case closePreview
    }

    enum RewriteStatus {
        case rewriting
        case done
        case error(String)
    }

    // Grab selected text and show the command palette near the cursor.
    func grabSelectionAndShowPalette() {
        // Block re-entrant calls — ignore if already processing
        guard !isProcessing else {
            logger.notice("rewrite already in progress — ignoring trigger")
            return
        }
        isProcessing = true

        // Remember which app was frontmost so we can paste back into it
        let sourceApp = NSWorkspace.shared.frontmostApplication

        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        // Save original clipboard contents to restore later
        let savedItems = saveClipboard(pasteboard)

        if let focusedTextContext = focusedTextContext() {
            activeSession = RewriteSession(
                selectedText: focusedTextContext.selectedText,
                selectedWordCount: Self.wordCount(in: focusedTextContext.selectedText),
                sourceApp: sourceApp,
                savedItems: savedItems
            )
            CommandPaletteWindowController.shared.show(
                selectedText: focusedTextContext.selectedText,
                anchorRect: focusedTextContext.caretRect
            )
            return
        }

        // Fall back to Cmd+C for apps that do not expose focused text through Accessibility.
        simulateKeyPress(keyCode: UInt16(kVK_ANSI_C), modifiers: .maskCommand)

        // Poll for clipboard change instead of fixed delay (up to 500ms)
        pollClipboardChange(pasteboard: pasteboard, expected: changeCountBefore, attempts: 10, interval: 0.05) { changed in
            if !changed {
                logger.notice("clipboard unchanged — opening palette with no selected text")
            }

            let selectedText = changed ? (pasteboard.string(forType: .string) ?? "") : ""

            self.activeSession = RewriteSession(
                selectedText: selectedText,
                selectedWordCount: Self.wordCount(in: selectedText),
                sourceApp: sourceApp,
                savedItems: savedItems
            )
            CommandPaletteWindowController.shared.show(selectedText: selectedText)
        }
    }

    private func focusedTextContext() -> FocusedTextContext? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success else {
            return nil
        }

        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        let selectedText = selectedText(from: element) ?? ""
        let caretRect = selectedTextBounds(from: element)
        guard !selectedText.isEmpty || caretRect != nil else { return nil }
        return FocusedTextContext(selectedText: selectedText, caretRect: caretRect)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func selectedTextBounds(from element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
              let rangeAXValue = rangeValue,
              CFGetTypeID(rangeAXValue) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(rangeAXValue as! AXValue, .cfRange, &range) else {
            return nil
        }

        var lookupRange = range
        if lookupRange.length == 0 {
            lookupRange.length = 1
        }

        guard let lookupRangeValue = AXValueCreate(.cfRange, &lookupRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        var result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            lookupRangeValue,
            &boundsValue
        )

        if result != .success, range.length == 0 {
            lookupRange.length = 0
            if let insertionRangeValue = AXValueCreate(.cfRange, &lookupRange) {
                result = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    insertionRangeValue,
                    &boundsValue
                )
            }
        }

        guard result == .success,
              let boundsAXValue = boundsValue,
              CFGetTypeID(boundsAXValue) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsAXValue as! AXValue, .cgRect, &rect), !rect.isNull else {
            return nil
        }
        return rect
    }

    // Legacy direct rewrite path. Kept for older entry points.
    func grabRewriteAndPaste() {
        let mode = UserSettings.shared.rewriteMode
        grabSelectionAndRun(historyLabel: mode.label) { text in
            try await RewriteDispatcher.shared.generate(text, mode: mode)
        }
    }

    func cancelPaletteSession() {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil
        activeRequestID = nil

        if let pendingPreview {
            if !didCopyPendingPreview {
                restoreClipboard(NSPasteboard.general, items: pendingPreview.session.savedItems)
            }
        } else if let session = activeSession {
            restoreClipboard(NSPasteboard.general, items: session.savedItems)
        }

        pendingPreview = nil
        didCopyPendingPreview = false
        activeSession = nil
        onStatusChange?(.done)
        isProcessing = false
    }

    @discardableResult
    func copyPreviewResult() -> Bool {
        guard let pendingPreview else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pendingPreview.result, forType: .string)
        didCopyPendingPreview = true
        return true
    }

    func pastePreviewResult() {
        guard let pendingPreview else { return }
        let preview = pendingPreview
        self.pendingPreview = nil
        didCopyPendingPreview = false
        paste(
            preview.result,
            into: preview.session,
            previewImages: preview.images,
            presentation: .closePreview
        )
    }

    func runSavedAction(
        _ action: UserSettings.SavedAction,
        route: GenerationRoute = .auto,
        images: [PromptImageAttachment] = []
    ) {
        runPaletteRewrite(
            title: action.name,
            historyLabel: action.name,
            images: images
        ) { text in
            try await RewriteDispatcher.shared.generate(
                text,
                action: action,
                route: route,
                images: images
            )
        }
    }

    func runCustomInstruction(
        _ instruction: String,
        route: GenerationRoute = .auto,
        images: [PromptImageAttachment] = []
    ) {
        runPaletteRewrite(
            title: "Running custom prompt",
            historyLabel: "Custom prompt",
            images: images
        ) { text in
            try await RewriteDispatcher.shared.generate(
                text,
                customInstruction: instruction,
                route: route,
                images: images
            )
        }
    }

    private func runPaletteRewrite(
        title: String,
        historyLabel: String,
        images: [PromptImageAttachment],
        request: @escaping (String) async throws -> GenerationResult
    ) {
        guard let session = activeSession else {
            isProcessing = false
            return
        }
        let requestID = UUID()
        activeRequestID = requestID

        onStatusChange?(.rewriting)
        let isGenerating = session.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        CommandPaletteWindowController.shared.showRunning(
            title: title,
            subtitle: isGenerating ? "Generating text" : "Replacing selected text"
        )

        activeRewriteTask?.cancel()
        activeRewriteTask = Task {
            do {
                let generation = try await request(session.selectedText)
                await MainActor.run {
                    guard self.activeRequestID == requestID else { return }
                    GenerationHistoryStore.shared.add(
                        result: generation.text,
                        actionLabel: historyLabel,
                        provider: generation.provider,
                        model: generation.model,
                        selectedWordCount: session.selectedWordCount,
                        imageFileNames: images.map(\.fileName)
                    )
                    let isGenerating = session.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    self.pendingPreview = PendingPreview(
                        result: generation.text,
                        session: session,
                        images: images
                    )
                    self.didCopyPendingPreview = false
                    self.activeRewriteTask = nil
                    self.activeRequestID = nil
                    self.onStatusChange?(.done)
                    CommandPaletteWindowController.shared.showTextResult(
                        text: generation.text,
                        title: historyLabel,
                        subtitle: isGenerating ? "Ready to insert" : "Ready to paste",
                        images: images
                    )
                }
            } catch {
                logger.error("rewrite failed: \(error.localizedDescription)")
                await MainActor.run {
                    guard self.activeRequestID == requestID else { return }
                    self.activeRewriteTask = nil
                    self.restoreClipboard(NSPasteboard.general, items: session.savedItems)
                    self.activeRequestID = nil
                    self.activeSession = nil
                    self.onStatusChange?(.error(error.localizedDescription))
                    CommandPaletteWindowController.shared.showError(error.localizedDescription)
                    self.showErrorNotification(error.localizedDescription)
                    self.isProcessing = false
                }
            }
        }
    }

    private func grabSelectionAndRun(
        historyLabel: String,
        request: @escaping (String) async throws -> GenerationResult
    ) {
        guard !isProcessing else {
            logger.notice("rewrite already in progress — ignoring trigger")
            return
        }
        isProcessing = true

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount
        let savedItems = saveClipboard(pasteboard)

        simulateKeyPress(keyCode: UInt16(kVK_ANSI_C), modifiers: .maskCommand)

        pollClipboardChange(pasteboard: pasteboard, expected: changeCountBefore, attempts: 10, interval: 0.05) { changed in
            guard changed else {
                logger.notice("clipboard unchanged — no selection or missing permission")
                self.restoreClipboard(pasteboard, items: savedItems)
                self.isProcessing = false
                return
            }

            let selectedText = pasteboard.string(forType: .string) ?? ""
            guard !selectedText.isEmpty else {
                self.restoreClipboard(pasteboard, items: savedItems)
                self.isProcessing = false
                return
            }

            self.onStatusChange?(.rewriting)

            Task {
                do {
                    let generation = try await request(selectedText)
                    await MainActor.run {
                        let session = RewriteSession(
                            selectedText: selectedText,
                            selectedWordCount: Self.wordCount(in: selectedText),
                            sourceApp: sourceApp,
                            savedItems: savedItems
                        )
                        GenerationHistoryStore.shared.add(
                            result: generation.text,
                            actionLabel: historyLabel,
                            provider: generation.provider,
                            model: generation.model,
                            selectedWordCount: session.selectedWordCount,
                            imageFileNames: []
                        )
                        self.paste(generation.text, into: session)
                    }
                } catch {
                    logger.error("rewrite failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.restoreClipboard(pasteboard, items: savedItems)
                        self.onStatusChange?(.error(error.localizedDescription))
                        self.showErrorNotification(error.localizedDescription)
                        self.isProcessing = false
                    }
                }
            }
        }
    }

    private func paste(
        _ rewritten: String,
        into session: RewriteSession,
        previewImages: [PromptImageAttachment] = [],
        presentation: PastePresentation = .status
    ) {
        let pasteboard = NSPasteboard.general
        let isGenerating = session.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Re-activate the original app before pasting
        session.sourceApp?.activate()

        // Small delay to let the app come to front
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            pasteboard.setString(rewritten, forType: .string)

            // Simulate Cmd+V to paste
            self.simulateKeyPress(keyCode: UInt16(kVK_ANSI_V), modifiers: .maskCommand)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.activeRewriteTask = nil
                self.activeRequestID = nil
                self.activeSession = nil
                self.onStatusChange?(.done)
                switch presentation {
                case .status:
                    CommandPaletteWindowController.shared.showSuccess(
                        subtitle: isGenerating ? "Copied to clipboard" : "Selection replaced and copied"
                    )
                case .closePreview:
                    CommandPaletteWindowController.shared.dismissAfterPreviewAction()
                }
                self.isProcessing = false
            }
        }
    }

    // Poll clipboard changeCount instead of assuming a fixed delay is enough
    private func pollClipboardChange(pasteboard: NSPasteboard, expected: Int, attempts: Int, interval: TimeInterval, completion: @escaping (Bool) -> Void) {
        if pasteboard.changeCount != expected {
            completion(true)
            return
        }
        if attempts <= 0 {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            self.pollClipboardChange(pasteboard: pasteboard, expected: expected, attempts: attempts - 1, interval: interval, completion: completion)
        }
    }

    // Save all clipboard items so we can restore them later
    private func saveClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        var saved: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }
        return saved
    }

    // Restore previously saved clipboard contents
    private func restoreClipboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func wordCount(in text: String) -> Int {
        text
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    // Show a macOS notification for errors
    private func showErrorNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Companion"
        content.body = "Companion failed: \(message)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Simulate a key press with modifiers using CGEvent
    private func simulateKeyPress(keyCode: UInt16, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
