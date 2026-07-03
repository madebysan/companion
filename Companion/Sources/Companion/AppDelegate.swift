import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var onboardingWindow: OnboardingWindow?
    private var settingsWindow: SettingsWindow?
    private var aboutWindow: NSWindow?
    private var permissionTimer: Timer?
    private var wasPermissionsOK = false
    private var appObserver: NSObjectProtocol?
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isPreviewLaunch = isPreviewMode()
        installMainMenu()

        // Check accessibility permission
        if !isPreviewLaunch {
            checkAccessibilityPermission()
        }

        // Request notification permission so fallback + error notifications show
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Set up menu bar
        statusBarController = StatusBarController(appDelegate: self)
        statusBarController?.setup()

        // Register global hotkey
        if !isPreviewLaunch {
            HotkeyManager.shared.register()
        }

        // Register Services menu provider (right-click > Services > Fix Grammar)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        // Start periodic permission monitoring
        if !isPreviewLaunch {
            wasPermissionsOK = AXIsProcessTrusted() && SettingsWindow.checkInputMonitoring()
            startPermissionMonitoring()
        }

        // Show onboarding if first launch
        if !isPreviewLaunch && !UserSettings.shared.hasCompletedOnboarding {
            showOnboarding()
        }

        showPalettePreviewIfRequested()
        showSettingsPreviewIfRequested()
    }

    private func isPreviewMode() -> Bool {
        let processInfo = ProcessInfo.processInfo
        let arguments = processInfo.arguments
        return processInfo.environment["COMPANION_PALETTE_PREVIEW"] == "1"
            || arguments.contains("--palette-preview")
            || arguments.contains("--palette-long-preview")
            || arguments.contains("--palette-loading-preview")
            || arguments.contains("--palette-result-preview")
            || arguments.contains("--settings-preview")
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "Companion")
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Companion",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Companion",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]

        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func showOnboarding() {
        onboardingWindow = OnboardingWindow()
        onboardingWindow?.showWindow(nil)
        onboardingWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPalettePreviewIfRequested() {
        let processInfo = ProcessInfo.processInfo
        let arguments = processInfo.arguments
        let isPreview = processInfo.environment["COMPANION_PALETTE_PREVIEW"] == "1"
            || arguments.contains("--palette-preview")
            || arguments.contains("--palette-long-preview")
            || arguments.contains("--palette-loading-preview")
            || arguments.contains("--palette-result-preview")
        guard isPreview else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            CommandPaletteWindowController.shared.show(
                selectedText: "Tomorrow I wont make it to dinner sorry maybe sunday?"
            )

            if arguments.contains("--palette-long-preview") {
                CommandPaletteWindowController.shared.showPreviewInstruction(
                    "write an email to john telling him that I fixed it and attach this text also suggest 3 parks in manhattan to go on friday with him"
                )
            } else if arguments.contains("--palette-loading-preview") {
                CommandPaletteWindowController.shared.showRunning(title: "Running custom prompt")
            } else if arguments.contains("--palette-result-preview") {
                CommandPaletteWindowController.shared.showTextResult(
                    text: "Dear Emily,\n\nI hope this message finds you well. I would like to schedule a meeting to discuss our marketing strategy brainstorm and align on next steps.\n\nWould Tuesday or Thursday at 3 PM work for you? If not, please send a few times that are more convenient.\n\nBest,\nSantiago",
                    title: "Email Writer",
                    subtitle: "Ready to paste"
                )
            }
        }
    }

    private func showSettingsPreviewIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--settings-preview") else { return }

        let pane = arguments
            .first(where: { $0.hasPrefix("--settings-pane=") })?
            .replacingOccurrences(of: "--settings-pane=", with: "")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.openSettings()
            if let pane {
                self.settingsWindow?.selectPane(named: pane)
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openAbout() {
        if aboutWindow == nil {
            aboutWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            aboutWindow?.title = "About Companion"
            aboutWindow?.center()
            aboutWindow?.isReleasedWhenClosed = false

            let contentView = aboutWindow?.contentView ?? NSView()

            // Icon
            let iconView = NSImageView(frame: .zero)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            if let image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Companion") {
                let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .light)
                iconView.image = image.withSymbolConfiguration(config)
                iconView.contentTintColor = .controlAccentColor
            }
            contentView.addSubview(iconView)

            // Title
            let titleLabel = NSTextField(labelWithString: "Companion")
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
            titleLabel.alignment = .center
            contentView.addSubview(titleLabel)

            // Version
            let versionLabel = NSTextField(labelWithString: "Version \(Self.appVersionString())")
            versionLabel.translatesAutoresizingMaskIntoConstraints = false
            versionLabel.font = .systemFont(ofSize: 11)
            versionLabel.textColor = .secondaryLabelColor
            versionLabel.alignment = .center
            contentView.addSubview(versionLabel)

            // Description
            let descLabel = NSTextField(labelWithString: "Run saved or custom AI actions on selected text.")
            descLabel.translatesAutoresizingMaskIntoConstraints = false
            descLabel.font = .systemFont(ofSize: 12)
            descLabel.textColor = .secondaryLabelColor
            descLabel.alignment = .center
            contentView.addSubview(descLabel)

            // "Made by santiagoalonso.com" clickable link
            let creditButton = NSButton(frame: .zero)
            creditButton.translatesAutoresizingMaskIntoConstraints = false
            creditButton.isBordered = false

            let madeBy = NSMutableAttributedString(
                string: "Made by ",
                attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11)
                ]
            )
            let link = NSAttributedString(
                string: "santiagoalonso.com",
                attributes: [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: NSFont.systemFont(ofSize: 11)
                ]
            )
            madeBy.append(link)
            creditButton.attributedTitle = madeBy
            creditButton.target = self
            creditButton.action = #selector(openWebsite)
            contentView.addSubview(creditButton)

            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
                iconView.widthAnchor.constraint(equalToConstant: 48),
                iconView.heightAnchor.constraint(equalToConstant: 48),

                titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),

                versionLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

                descLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                descLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),

                creditButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                creditButton.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 8),
            ])
        }

        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://santiagoalonso.com") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !trusted {
            NSLog("Companion: Accessibility permission not granted. The app needs this to simulate Cmd+C/Cmd+V.")
        }
    }

    private func startPermissionMonitoring() {
        // Check every 120 seconds instead of 10 — permissions rarely change,
        // and each check creates/destroys a CGEvent tap
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.recheckPermissions()
        }

        // Also re-check when the app becomes active (user returned from System Settings)
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            self.recheckPermissions()
        }
    }

    private func recheckPermissions() {
        let accessOK = AXIsProcessTrusted()
        let inputOK = SettingsWindow.checkInputMonitoring()
        let allOK = accessOK && inputOK

        if wasPermissionsOK && !allOK {
            DispatchQueue.main.async {
                self.statusBarController?.showPermissionWarning(true)
            }
            showPermissionLostNotification(accessibility: !accessOK, inputMonitoring: !inputOK)
        } else if !wasPermissionsOK && allOK {
            DispatchQueue.main.async {
                self.statusBarController?.showPermissionWarning(false)
            }
        }

        wasPermissionsOK = allOK
    }

    private func showPermissionLostNotification(accessibility: Bool, inputMonitoring: Bool) {
        var missing: [String] = []
        if accessibility { missing.append("Accessibility") }
        if inputMonitoring { missing.append("Input Monitoring") }

        let content = UNMutableNotificationContent()
        content.title = "Companion shortcut stopped working"
        content.body = "Missing permission: \(missing.joined(separator: " and ")). Open Companion settings or go to System Settings → Privacy & Security to fix."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "permission-lost",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
