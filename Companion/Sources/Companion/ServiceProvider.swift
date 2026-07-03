import AppKit
import os.log

private let logger = Logger(subsystem: "com.santiagoalonso.companion", category: "ServiceProvider")

// Handles the macOS Services menu "Fix Grammar" action (right-click > Services)
final class ServiceProvider: NSObject {

    // Called by macOS when the user selects "Fix Grammar" from the Services menu.
    // Receives selected text via pasteboard, rewrites it, and returns the result.
    @objc func fixGrammar(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text selected" as NSString
            return
        }

        logger.info("Service invoked with \(text.count) characters")

        // Update menu bar icon to show activity
        Task { @MainActor in
            TextGrabber.shared.onStatusChange?(.rewriting)
        }

        // Services is invoked from the "Fix Grammar" context menu, so use fix grammar mode
        let mode = UserSettings.RewriteMode.fixGrammar

        // Dispatch synchronously (Services expects a synchronous return)
        let semaphore = DispatchSemaphore(value: 0)
        var rewritten: String?
        var apiError: Error?

        Task {
            do {
                rewritten = try await RewriteDispatcher.shared.rewrite(text, mode: mode)
            } catch {
                apiError = error
            }
            semaphore.signal()
        }

        // Wait up to 30 seconds for the API response
        let result = semaphore.wait(timeout: .now() + 30)

        if result == .timedOut {
            error.pointee = "Request timed out" as NSString
            Task { @MainActor in
                TextGrabber.shared.onStatusChange?(.error("Request timed out"))
            }
            return
        }

        if let apiError {
            error.pointee = apiError.localizedDescription as NSString
            Task { @MainActor in
                TextGrabber.shared.onStatusChange?(.error(apiError.localizedDescription))
            }
            return
        }

        guard let rewritten, !rewritten.isEmpty else {
            error.pointee = "Empty response from API" as NSString
            Task { @MainActor in
                TextGrabber.shared.onStatusChange?(.error("Empty response"))
            }
            return
        }

        // Write the rewritten text back — macOS replaces the selection with this
        pasteboard.clearContents()
        pasteboard.setString(rewritten, forType: .string)

        Task { @MainActor in
            TextGrabber.shared.onStatusChange?(.done)
        }

        logger.info("Service completed — returned \(rewritten.count) characters")
    }
}
