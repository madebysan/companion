import AppKit

// First-launch welcome screen with API key entry and permissions guide
final class OnboardingWindow: NSWindowController {
    private var providerPopup: NSPopUpButton!
    private var apiKeyLabel: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var apiHintLabel: NSTextField!
    private var apiKeyLinkButton: NSButton!
    private var getStartedButton: NSButton!
    private var skipButton: NSButton!
    private var statusLabel: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Companion"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // App icon
        let iconView = NSImageView(frame: .zero)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Companion") {
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
            iconView.image = image.withSymbolConfiguration(config)
            iconView.contentTintColor = .controlAccentColor
        }
        contentView.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(labelWithString: "Companion")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.alignment = .center
        contentView.addSubview(titleLabel)

        // Description
        let descLabel = NSTextField(wrappingLabelWithString:
            "Transform selected text with one keystroke.\n\n" +
            "Open a command palette, pick a saved action, or type a one-off instruction. Use local models through LM Studio or connect the cloud provider you already use."
        )
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = .systemFont(ofSize: 13)
        descLabel.alignment = .center
        descLabel.textColor = .secondaryLabelColor
        contentView.addSubview(descLabel)

        // Permissions info box
        let permBox = NSBox()
        permBox.translatesAutoresizingMaskIntoConstraints = false
        permBox.boxType = .custom
        permBox.cornerRadius = 8
        permBox.borderColor = .separatorColor
        permBox.borderWidth = 1
        permBox.fillColor = NSColor.controlBackgroundColor
        permBox.titlePosition = .noTitle
        contentView.addSubview(permBox)

        let permLabel = NSTextField(wrappingLabelWithString:
            "After setup, macOS will ask you to grant two permissions in System Settings → Privacy & Security:\n\n" +
            "  1. Accessibility — so Companion can copy and paste text\n" +
            "  2. Input Monitoring — so the global shortcut works everywhere\n\n" +
            "Both are required. You may need to relaunch Companion after granting them."
        )
        permLabel.translatesAutoresizingMaskIntoConstraints = false
        permLabel.font = .systemFont(ofSize: 11.5)
        permLabel.textColor = .secondaryLabelColor
        permBox.addSubview(permLabel)

        let providerLabel = NSTextField(labelWithString: "Start with")
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        providerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        providerLabel.textColor = .secondaryLabelColor
        contentView.addSubview(providerLabel)

        providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        addProviderItem(title: "fal / OpenRouter", id: "fal")
        addProviderItem(title: "OpenAI", id: "openai")
        addProviderItem(title: "Claude", id: "claude")
        addProviderItem(title: "Local only", id: "local")
        contentView.addSubview(providerPopup)

        // API key label
        apiKeyLabel = NSTextField(labelWithString: "API Key")
        apiKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        apiKeyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        apiKeyLabel.textColor = .secondaryLabelColor
        contentView.addSubview(apiKeyLabel)

        // Helper text under the label
        apiHintLabel = NSTextField(wrappingLabelWithString: "")
        apiHintLabel.translatesAutoresizingMaskIntoConstraints = false
        apiHintLabel.font = .systemFont(ofSize: 11)
        apiHintLabel.textColor = .tertiaryLabelColor
        contentView.addSubview(apiHintLabel)

        // API key field
        apiKeyField = NSSecureTextField(frame: .zero)
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged)
        contentView.addSubview(apiKeyField)

        // "Get an API key" link
        apiKeyLinkButton = NSButton(title: "", target: self, action: #selector(openAPIKeyPage))
        apiKeyLinkButton.translatesAutoresizingMaskIntoConstraints = false
        apiKeyLinkButton.isBordered = false
        apiKeyLinkButton.contentTintColor = .linkColor
        apiKeyLinkButton.font = .systemFont(ofSize: 12)
        contentView.addSubview(apiKeyLinkButton)

        // Status label (for validation feedback)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.alignment = .center
        contentView.addSubview(statusLabel)

        // Get Started button
        getStartedButton = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
        getStartedButton.translatesAutoresizingMaskIntoConstraints = false
        getStartedButton.bezelStyle = .rounded
        getStartedButton.controlSize = .large
        getStartedButton.keyEquivalent = "\r"
        getStartedButton.isEnabled = false
        contentView.addSubview(getStartedButton)

        // Skip button — proceed without API key (local-only mode)
        skipButton = NSButton(title: "Skip for now", target: self, action: #selector(skipOnboarding))
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.bezelStyle = .accessoryBarAction
        skipButton.controlSize = .regular
        skipButton.isBordered = false
        skipButton.contentTintColor = .secondaryLabelColor
        contentView.addSubview(skipButton)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 32),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),

            descLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            descLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            descLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),

            permBox.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            permBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            permBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

            permLabel.topAnchor.constraint(equalTo: permBox.topAnchor, constant: 12),
            permLabel.leadingAnchor.constraint(equalTo: permBox.leadingAnchor, constant: 14),
            permLabel.trailingAnchor.constraint(equalTo: permBox.trailingAnchor, constant: -14),
            permLabel.bottomAnchor.constraint(equalTo: permBox.bottomAnchor, constant: -12),

            providerLabel.topAnchor.constraint(equalTo: permBox.bottomAnchor, constant: 16),
            providerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),

            providerPopup.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            providerPopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),
            providerPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -60),

            apiKeyLabel.topAnchor.constraint(equalTo: providerPopup.bottomAnchor, constant: 12),
            apiKeyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),

            apiHintLabel.topAnchor.constraint(equalTo: apiKeyLabel.bottomAnchor, constant: 2),
            apiHintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),
            apiHintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -60),

            apiKeyField.topAnchor.constraint(equalTo: apiHintLabel.bottomAnchor, constant: 6),
            apiKeyField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),
            apiKeyField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -60),

            apiKeyLinkButton.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 6),
            apiKeyLinkButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: apiKeyLinkButton.bottomAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),

            getStartedButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            getStartedButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            skipButton.topAnchor.constraint(equalTo: getStartedButton.bottomAnchor, constant: 4),
            skipButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            skipButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])

        updateProviderSelection()
    }

    private func addProviderItem(title: String, id: String) {
        providerPopup.addItem(withTitle: title)
        providerPopup.lastItem?.representedObject = id
    }

    @objc private func apiKeyChanged() {
        updateGetStartedState()
        statusLabel.stringValue = ""
    }

    @objc private func providerChanged() {
        apiKeyField.stringValue = ""
        statusLabel.stringValue = ""
        updateProviderSelection()
    }

    @objc private func skipOnboarding() {
        UserSettings.shared.hasCompletedOnboarding = true
        self.close()
    }

    @objc private func openAPIKeyPage() {
        let urlString: String
        switch selectedProviderID {
        case "openai":
            urlString = "https://platform.openai.com/api-keys"
        case "claude":
            urlString = "https://console.anthropic.com/settings/keys"
        default:
            urlString = "https://fal.ai/dashboard/keys"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func getStarted() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch selectedProviderID {
        case "fal":
            guard !key.isEmpty else { return }
            UserSettings.shared.falAPIKey = key
            UserSettings.shared.customPromptProvider = .fal
        case "openai":
            guard !key.isEmpty else { return }
            UserSettings.shared.openAIAPIKey = key
            UserSettings.shared.customPromptProvider = .openAI
        case "claude":
            guard !key.isEmpty else { return }
            UserSettings.shared.apiKey = key
            UserSettings.shared.customPromptProvider = .claude
        default:
            break
        }
        UserSettings.shared.hasCompletedOnboarding = true
        statusLabel.stringValue = ""
        close()
    }

    private var selectedProviderID: String {
        providerPopup.selectedItem?.representedObject as? String ?? "fal"
    }

    private func updateProviderSelection() {
        switch selectedProviderID {
        case "openai":
            apiKeyLabel.stringValue = "OpenAI API Key"
            apiHintLabel.stringValue = "Use OpenAI directly with your own key. You can change the model later in Settings."
            apiKeyField.placeholderString = "OPENAI_API_KEY"
            apiKeyField.isEnabled = true
            apiKeyLinkButton.title = "Get an OpenAI key"
            apiKeyLinkButton.isHidden = false
        case "claude":
            apiKeyLabel.stringValue = "Claude API Key"
            apiHintLabel.stringValue = "Use Claude directly with your own Anthropic key. You can change the model later in Settings."
            apiKeyField.placeholderString = "ANTHROPIC_API_KEY"
            apiKeyField.isEnabled = true
            apiKeyLinkButton.title = "Get a Claude key"
            apiKeyLinkButton.isHidden = false
        case "local":
            apiKeyLabel.stringValue = "API Key"
            apiHintLabel.stringValue = "No key needed. Set up LM Studio in Settings after Companion opens."
            apiKeyField.placeholderString = ""
            apiKeyField.isEnabled = false
            apiKeyLinkButton.title = ""
            apiKeyLinkButton.isHidden = true
        default:
            apiKeyLabel.stringValue = "fal API Key"
            apiHintLabel.stringValue = "Use one fal key to reach OpenRouter models from Claude, OpenAI, Gemini, DeepSeek, and others."
            apiKeyField.placeholderString = "FAL_KEY"
            apiKeyField.isEnabled = true
            apiKeyLinkButton.title = "Get a fal key"
            apiKeyLinkButton.isHidden = false
        }
        updateGetStartedState()
    }

    private func updateGetStartedState() {
        if selectedProviderID == "local" {
            getStartedButton.isEnabled = true
            return
        }
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        getStartedButton.isEnabled = !key.isEmpty
    }
}
