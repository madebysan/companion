import AppKit
import Carbon.HIToolbox
import ServiceManagement

private final class FlippedPaneDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private let settingsDefaultWindowSize = NSSize(width: 740, height: 520)
private let settingsMinimumWindowSize = NSSize(width: 700, height: 420)
private let settingsPreferredMaximumWindowSize = NSSize(width: 780, height: 620)
private let settingsWindowScreenMargin: CGFloat = 64

// Settings window with provider routing, saved actions, shortcut, permissions, and launch behavior.
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private struct SettingsPaneItem {
        let title: String
        let symbolName: String
        let view: NSView
    }

    private var openAIAPIKeyField: NSSecureTextField!
    private var openAIModelField: NSTextField!
    private var claudeAPIKeyField: NSSecureTextField!
    private var claudeModelField: NSTextField!
    private var deepSeekAPIKeyField: NSSecureTextField!
    private var deepSeekModelField: NSTextField!
    private var falAPIKeyField: NSSecureTextField!
    private var actionPopup: NSPopUpButton!
    private var actionNameField: NSTextField!
    private var actionRoutePopup: NSPopUpButton!
    private var promptField: NSTextView!
    private var actions: [UserSettings.SavedAction] = []
    private var selectedActionIndex = 0
    private var modelRoutes: [UserSettings.ModelRoute] = []
    private var remoteCatalogModels: [UserSettings.RemoteCatalogModel] = []
    private var visibleRemoteCatalogModels: [UserSettings.RemoteCatalogModel] = []
    private var remoteCatalogFilterField: NSTextField!
    private var remoteCatalogTable: NSTableView!
    private var remoteCatalogStatusLabel: NSTextField!
    private var refreshRemoteModelsButton: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var shortcutLabel: NSTextField!
    private var shortcutMonitor: Any?
    private var lmStudioURLField: NSTextField!
    private var lmStudioModelPopup: NSPopUpButton!
    private var lmStudioStatusLabel: NSTextField!
    private var refreshModelsButton: NSButton!
    private var lmStudioVisionCheckbox: NSButton!
    private var fallbackCheckbox: NSButton!
    private var customPromptRoutePopup: NSPopUpButton!
    private var permissionsStack: NSStackView!
    private var sidebarTable: NSTableView!
    private var paneContainer: NSView!
    private var paneItems: [SettingsPaneItem] = []
    private var currentPaneConstraints: [NSLayoutConstraint] = []
    private var historyEntries: [GenerationHistoryStore.Entry] = []
    private var historyTable: NSTableView!
    private var historyResultView: NSTextView!
    private var historyMetadataLabel: NSTextField!
    private var copyHistoryButton: NSButton!

    private let labelWidth: CGFloat = 126

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: settingsDefaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Companion Settings"
        window.minSize = settingsMinimumWindowSize
        window.setFrameAutosaveName("CompanionSettingsWindow")
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        setupUI()
        fitWindowToVisibleScreen()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        fitWindowToVisibleScreen()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        actions = UserSettings.shared.savedActions
        modelRoutes = UserSettings.shared.configuredModelRoutes
        remoteCatalogModels = UserSettings.shared.remoteCatalogModels

        paneItems = [
            SettingsPaneItem(title: "General", symbolName: "gearshape", view: makeGeneralPane()),
            SettingsPaneItem(title: "Providers", symbolName: "network", view: makeProvidersPane()),
            SettingsPaneItem(title: "Actions", symbolName: "text.badge.star", view: makeActionsPane()),
            SettingsPaneItem(title: "History", symbolName: "clock.arrow.circlepath", view: makeHistoryPane()),
            SettingsPaneItem(title: "Shortcut", symbolName: "keyboard", view: makeShortcutPane()),
            SettingsPaneItem(title: "Permissions", symbolName: "hand.raised", view: makePermissionsPane()),
        ]

        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        contentView.addSubview(splitView)

        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.borderType = .noBorder

        sidebarTable = NSTableView()
        sidebarTable.headerView = nil
        sidebarTable.rowHeight = 34
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarTable.backgroundColor = .clear
        sidebarTable.style = .sourceList
        sidebarTable.delegate = self
        sidebarTable.dataSource = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)
        sidebarScroll.documentView = sidebarTable

        paneContainer = NSView()
        paneContainer.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(sidebarScroll)
        splitView.addArrangedSubview(paneContainer)

        sidebarTable.reloadData()
        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPane(at: 0)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 168),
        ])

        Task { @MainActor in
            await self.loadModelsList(isInitialLoad: true)
        }
    }

    func selectPane(named title: String) {
        guard let index = paneItems.firstIndex(where: { $0.title == title }) else { return }
        sidebarTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        showPane(at: index)
        window?.layoutIfNeeded()
    }

    private func showPane(at index: Int) {
        guard paneItems.indices.contains(index) else { return }

        NSLayoutConstraint.deactivate(currentPaneConstraints)
        currentPaneConstraints.removeAll()
        paneContainer.subviews.forEach { $0.removeFromSuperview() }

        let pane = paneItems[index].view
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(pane)

        currentPaneConstraints = [
            pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(currentPaneConstraints)
        resetScrollPositionIfNeeded(for: pane)
    }

    private func fitWindowToVisibleScreen() {
        guard let window else { return }
        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let visibleMaxWidth = max(window.minSize.width, visibleFrame.width - settingsWindowScreenMargin)
        let visibleMaxHeight = max(window.minSize.height, visibleFrame.height - settingsWindowScreenMargin)
        let maxWidth = min(settingsPreferredMaximumWindowSize.width, visibleMaxWidth)
        let maxHeight = min(settingsPreferredMaximumWindowSize.height, visibleMaxHeight)
        window.maxSize = NSSize(width: maxWidth, height: maxHeight)

        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), maxWidth)
        frame.size.height = min(max(frame.height, window.minSize.height), maxHeight)

        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }

        window.setFrame(frame, display: false)
    }

    private func resetScrollPositionIfNeeded(for pane: NSView) {
        guard let scrollView = pane as? NSScrollView else { return }

        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func makeGeneralPane() -> NSView {
        makePane { stack in
            addSection(
                "Behavior",
                help: "Control how Companion runs in the background.",
                to: stack
            ) { section in
                launchAtLoginCheckbox = NSButton(
                    checkboxWithTitle: "Launch Companion at login",
                    target: self,
                    action: #selector(toggleLaunchAtLogin)
                )
                launchAtLoginCheckbox.state = UserSettings.shared.launchAtLogin ? .on : .off
                section.addArrangedSubview(launchAtLoginCheckbox)

                section.addArrangedSubview(makeHelpLabel(
                    "Companion stays in the menu bar and opens the command palette with your global shortcut."
                ))
            }

            addSection(
                "App",
                help: "Version and support links live outside provider/action setup.",
                to: stack
            ) { section in
                section.addArrangedSubview(makeInfoRow(label: "Version", value: appVersionString()))
                section.addArrangedSubview(makeInfoRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "Unknown"))
                section.addArrangedSubview(makeHelpLabel(
                    "About, quit, and status commands are available from the Companion menu bar icon."
                ))
            }

            addSection(
                "Credits",
                help: "Companion is made by Santiago Alonso.",
                to: stack
            ) { section in
                section.addArrangedSubview(makeInfoRow(label: "Made by", value: "Santiago Alonso"))
                section.addArrangedSubview(makeSettingsRow(
                    label: "Website",
                    control: makeLinkButton("santiagoalonso.com", action: #selector(openCreatorWebsite))
                ))
            }
        }
    }

    private func makeProvidersPane() -> NSView {
        makePane { stack in
            addSection(
                "Direct Providers",
                help: "Optional cloud routes. Add a key for the provider you already use, then choose that route in Actions or the palette.",
                to: stack
            ) { section in
                openAIAPIKeyField = makeSecureField(
                    value: UserSettings.shared.openAIAPIKey,
                    placeholder: "OPENAI_API_KEY"
                )
                openAIAPIKeyField.target = self
                openAIAPIKeyField.action = #selector(openAIAPIKeyChanged)
                openAIAPIKeyField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "OpenAI key", control: openAIAPIKeyField))

                openAIModelField = makeTextField(
                    value: UserSettings.shared.openAIModel,
                    placeholder: UserSettings.defaultOpenAIModel,
                    monospaced: true
                )
                openAIModelField.target = self
                openAIModelField.action = #selector(openAIModelChanged)
                openAIModelField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "OpenAI model", control: openAIModelField))

                claudeAPIKeyField = makeSecureField(
                    value: UserSettings.shared.apiKey,
                    placeholder: "ANTHROPIC_API_KEY"
                )
                claudeAPIKeyField.target = self
                claudeAPIKeyField.action = #selector(claudeAPIKeyChanged)
                claudeAPIKeyField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "Claude key", control: claudeAPIKeyField))

                claudeModelField = makeTextField(
                    value: UserSettings.shared.claudeModel,
                    placeholder: UserSettings.defaultClaudeModel,
                    monospaced: true
                )
                claudeModelField.target = self
                claudeModelField.action = #selector(claudeModelChanged)
                claudeModelField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "Claude model", control: claudeModelField))

                deepSeekAPIKeyField = makeSecureField(
                    value: UserSettings.shared.deepSeekAPIKey,
                    placeholder: "DEEPSEEK_API_KEY"
                )
                deepSeekAPIKeyField.target = self
                deepSeekAPIKeyField.action = #selector(deepSeekAPIKeyChanged)
                deepSeekAPIKeyField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "DeepSeek key", control: deepSeekAPIKeyField))

                deepSeekModelField = makeTextField(
                    value: UserSettings.shared.deepSeekModel,
                    placeholder: UserSettings.defaultDeepSeekModel,
                    monospaced: true
                )
                deepSeekModelField.target = self
                deepSeekModelField.action = #selector(deepSeekModelChanged)
                deepSeekModelField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "DeepSeek model", control: deepSeekModelField))

                section.addArrangedSubview(makeHelpLabel(
                    "Keys stay on this Mac. Leave these blank if you only want LM Studio or OpenRouter through fal."
                ))
            }

            addSection(
                "Remote Provider",
                help: "One fal key can reach OpenRouter models from Claude, DeepSeek, Gemini, OpenAI, and others.",
                to: stack
            ) { section in
                falAPIKeyField = makeSecureField(
                    value: UserSettings.shared.falAPIKey,
                    placeholder: "FAL_KEY"
                )
                falAPIKeyField.target = self
                falAPIKeyField.action = #selector(falAPIKeyChanged)
                falAPIKeyField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "fal key", control: falAPIKeyField))

                section.addArrangedSubview(makeHelpLabel(
                    "The palette only shows fal/OpenRouter models when this key is configured."
                ))
            }

            addSection(
                "Remote Models",
                help: "Enable the fal/OpenRouter models you want available in the palette and saved-action model picker.",
                to: stack
            ) { section in
                refreshRemoteModelsButton = makeSmallButton("Refresh", action: #selector(refreshRemoteModels))

                remoteCatalogFilterField = makeTextField(
                    value: "",
                    placeholder: "Filter models, e.g. claude, openai, deepseek, gemini",
                    monospaced: false
                )
                remoteCatalogFilterField.delegate = self

                let filterControl = NSStackView()
                filterControl.orientation = .horizontal
                filterControl.alignment = .centerY
                filterControl.spacing = 8
                filterControl.addArrangedSubview(remoteCatalogFilterField)
                filterControl.addArrangedSubview(refreshRemoteModelsButton)
                section.addArrangedSubview(makeSettingsRow(label: "Models", control: filterControl))

                remoteCatalogTable = NSTableView()
                remoteCatalogTable.headerView = nil
                remoteCatalogTable.rowHeight = 38
                remoteCatalogTable.intercellSpacing = NSSize(width: 0, height: 2)
                remoteCatalogTable.backgroundColor = .clear
                remoteCatalogTable.delegate = self
                remoteCatalogTable.dataSource = self
                remoteCatalogTable.style = .inset
                remoteCatalogTable.allowsColumnResizing = true

                let enabledColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remoteEnabled"))
                enabledColumn.width = 42
                enabledColumn.minWidth = 42
                enabledColumn.maxWidth = 42
                remoteCatalogTable.addTableColumn(enabledColumn)

                let modelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remoteModel"))
                modelColumn.resizingMask = .autoresizingMask
                remoteCatalogTable.addTableColumn(modelColumn)

                let modelsScroll = NSScrollView()
                modelsScroll.translatesAutoresizingMaskIntoConstraints = false
                modelsScroll.hasVerticalScroller = true
                modelsScroll.borderType = .bezelBorder
                modelsScroll.documentView = remoteCatalogTable
                section.addArrangedSubview(modelsScroll)
                modelsScroll.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
                modelsScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true

                remoteCatalogStatusLabel = makeHelpLabel("")
                section.addArrangedSubview(remoteCatalogStatusLabel)

                refreshRemoteCatalogTable()
                if remoteCatalogModels.count <= UserSettings.defaultRemoteCatalogModelCount {
                    Task { @MainActor in
                        await self.loadRemoteModelCatalog()
                    }
                }
            }

            addSection(
                "Local Provider",
                help: "Use LM Studio when you want fast local rewrites.",
                to: stack
            ) { section in
                lmStudioURLField = makeTextField(
                    value: UserSettings.shared.lmStudioBaseURL,
                    placeholder: UserSettings.defaultLMStudioBaseURL,
                    monospaced: true
                )
                lmStudioURLField.target = self
                lmStudioURLField.action = #selector(lmStudioURLChanged)
                lmStudioURLField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "Server URL", control: lmStudioURLField))

                lmStudioModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
                lmStudioModelPopup.addItem(withTitle: "- not loaded -")
                lmStudioModelPopup.target = self
                lmStudioModelPopup.action = #selector(lmStudioModelChanged)
                lmStudioModelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

                refreshModelsButton = makeSmallButton("Refresh", action: #selector(refreshModels))

                let modelControl = NSStackView()
                modelControl.orientation = .horizontal
                modelControl.alignment = .centerY
                modelControl.spacing = 8
                modelControl.addArrangedSubview(lmStudioModelPopup)
                modelControl.addArrangedSubview(refreshModelsButton)
                section.addArrangedSubview(makeSettingsRow(label: "Loaded model", control: modelControl))

                lmStudioVisionCheckbox = NSButton(
                    checkboxWithTitle: "Selected local model supports image input",
                    target: self,
                    action: #selector(toggleLMStudioVision)
                )
                lmStudioVisionCheckbox.state = UserSettings.shared.lmStudioModelSupportsImages ? .on : .off
                section.addArrangedSubview(lmStudioVisionCheckbox)

                lmStudioStatusLabel = makeHelpLabel("Click Refresh to load available models.")
                section.addArrangedSubview(lmStudioStatusLabel)
            }

            addSection(
                "Routing",
                help: "Saved actions can use a specific model route. One-off prompts use this default.",
                to: stack
            ) { section in
                customPromptRoutePopup = makeRoutePopup(selectedRouteID: UserSettings.shared.customPromptRouteID)
                customPromptRoutePopup.target = self
                customPromptRoutePopup.action = #selector(customPromptRouteChanged)
                section.addArrangedSubview(makeSettingsRow(label: "Custom prompts", control: customPromptRoutePopup))

                fallbackCheckbox = NSButton(
                    checkboxWithTitle: "Use a remote model as fallback when the local model is unavailable",
                    target: self,
                    action: #selector(toggleFallback)
                )
                fallbackCheckbox.state = UserSettings.shared.fallbackToClaude ? .on : .off
                section.addArrangedSubview(fallbackCheckbox)
            }
        }
    }

    private func makeActionsPane() -> NSView {
        makePane { stack in
            addSection(
                "Saved Actions",
                help: "These appear in the command palette. Select an action to edit its name, model route, and prompt.",
                to: stack
            ) { section in
                actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
                actionPopup.target = self
                actionPopup.action = #selector(actionChanged)
                actionPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

                let actionPickerControl = NSStackView()
                actionPickerControl.orientation = .horizontal
                actionPickerControl.alignment = .centerY
                actionPickerControl.spacing = 8
                actionPickerControl.addArrangedSubview(actionPopup)
                actionPickerControl.addArrangedSubview(makeSmallButton("Add", action: #selector(addAction)))
                actionPickerControl.addArrangedSubview(makeSmallButton("Remove", action: #selector(removeAction)))
                actionPickerControl.addArrangedSubview(makeSmallButton("Up", action: #selector(moveActionUp)))
                actionPickerControl.addArrangedSubview(makeSmallButton("Down", action: #selector(moveActionDown)))
                section.addArrangedSubview(makeSettingsRow(label: "Action", control: actionPickerControl))

                actionNameField = makeTextField(value: "", placeholder: "Action name", monospaced: false)
                actionNameField.target = self
                actionNameField.action = #selector(actionNameChanged)
                actionNameField.delegate = self
                section.addArrangedSubview(makeSettingsRow(label: "Name", control: actionNameField))

                actionRoutePopup = makeRoutePopup(selectedRouteID: actions.first?.routeID)
                actionRoutePopup.target = self
                actionRoutePopup.action = #selector(actionRouteChanged)
                section.addArrangedSubview(makeSettingsRow(label: "Model", control: actionRoutePopup))

                let promptLabel = makeRowLabel("Prompt")
                let promptColumn = NSStackView()
                promptColumn.orientation = .vertical
                promptColumn.alignment = .width
                promptColumn.spacing = 8
                promptColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true

                let promptScroll = NSScrollView(frame: .zero)
                promptScroll.translatesAutoresizingMaskIntoConstraints = false
                promptScroll.hasVerticalScroller = true
                promptScroll.borderType = .bezelBorder
                promptScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true

                promptField = NSTextView(frame: .zero)
                promptField.string = ""
                promptField.font = .systemFont(ofSize: 13)
                promptField.isRichText = false
                promptField.isAutomaticQuoteSubstitutionEnabled = false
                promptField.isAutomaticDashSubstitutionEnabled = false
                promptField.textContainerInset = NSSize(width: 8, height: 8)
                promptField.isVerticallyResizable = true
                promptField.isHorizontallyResizable = false
                promptField.textContainer?.widthTracksTextView = true
                promptField.delegate = self
                promptScroll.documentView = promptField
                promptColumn.addArrangedSubview(promptScroll)
                promptScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true

                let resetPromptButton = makeSmallButton("Reset to Default", action: #selector(resetPrompt))
                resetPromptButton.setContentHuggingPriority(.required, for: .horizontal)
                promptColumn.addArrangedSubview(resetPromptButton)

                let promptRow = NSStackView()
                promptRow.orientation = .horizontal
                promptRow.alignment = .top
                promptRow.spacing = 10
                promptRow.addArrangedSubview(promptLabel)
                promptRow.addArrangedSubview(promptColumn)
                promptColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
                section.addArrangedSubview(promptRow)
                promptRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

                refreshActionEditor()
            }
        }
    }

    private func makeHistoryPane() -> NSView {
        makePane { stack in
            addSection(
                "Generated Text History",
                help: "Companion saves successful generated results locally so you can recover text if paste fails. Source text and image bytes are not stored.",
                to: stack
            ) { section in
                historyEntries = GenerationHistoryStore.shared.entries()

                let buttonRow = NSStackView()
                buttonRow.orientation = .horizontal
                buttonRow.alignment = .centerY
                buttonRow.spacing = 8
                copyHistoryButton = makeSmallButton("Copy Result", action: #selector(copyHistoryResult))
                buttonRow.addArrangedSubview(copyHistoryButton)
                buttonRow.addArrangedSubview(makeSmallButton("Clear History", action: #selector(clearHistory)))
                section.addArrangedSubview(buttonRow)

                historyTable = NSTableView()
                historyTable.headerView = nil
                historyTable.rowHeight = 44
                historyTable.intercellSpacing = NSSize(width: 0, height: 2)
                historyTable.backgroundColor = .clear
                historyTable.delegate = self
                historyTable.dataSource = self
                historyTable.style = .inset

                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
                column.resizingMask = .autoresizingMask
                historyTable.addTableColumn(column)

                let historyScroll = NSScrollView()
                historyScroll.translatesAutoresizingMaskIntoConstraints = false
                historyScroll.hasVerticalScroller = true
                historyScroll.borderType = .bezelBorder
                historyScroll.documentView = historyTable
                section.addArrangedSubview(historyScroll)
                historyScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
                historyScroll.heightAnchor.constraint(equalToConstant: 168).isActive = true

                historyMetadataLabel = makeHelpLabel("")
                section.addArrangedSubview(historyMetadataLabel)

                let resultScroll = NSScrollView()
                resultScroll.translatesAutoresizingMaskIntoConstraints = false
                resultScroll.hasVerticalScroller = true
                resultScroll.borderType = .bezelBorder

                historyResultView = NSTextView(frame: .zero)
                historyResultView.isEditable = false
                historyResultView.isSelectable = true
                historyResultView.isRichText = false
                historyResultView.font = .systemFont(ofSize: 12)
                historyResultView.textContainerInset = NSSize(width: 8, height: 8)
                historyResultView.string = ""
                resultScroll.documentView = historyResultView
                section.addArrangedSubview(resultScroll)
                resultScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
                resultScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true

                reloadHistory(selectFirst: true)
            }
        }
    }

    private func makeShortcutPane() -> NSView {
        makePane { stack in
            addSection(
                "Global Shortcut",
                help: "The shortcut opens the palette from any app. Press it again to close the palette.",
                to: stack
            ) { section in
                shortcutLabel = NSTextField(labelWithString: currentShortcutLabel())
                shortcutLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)

                let shortcutControl = NSStackView()
                shortcutControl.orientation = .horizontal
                shortcutControl.alignment = .centerY
                shortcutControl.spacing = 8
                shortcutControl.addArrangedSubview(shortcutLabel)
                shortcutControl.addArrangedSubview(makeSmallButton("Change...", action: #selector(recordShortcut)))
                shortcutControl.addArrangedSubview(makeSmallButton("Reset", action: #selector(resetShortcut)))
                section.addArrangedSubview(makeSettingsRow(label: "Shortcut", control: shortcutControl))

                section.addArrangedSubview(makeHelpLabel(
                    "If the shortcut does not trigger, another app may already own it. Record a different combination and make sure Input Monitoring is granted."
                ))
            }
        }
    }

    private func makePermissionsPane() -> NSView {
        makePane { stack in
            addSection(
                "Required Permissions",
                help: "Companion needs both permissions before it can work reliably across apps.",
                to: stack
            ) { section in
                permissionsStack = NSStackView()
                permissionsStack.orientation = .vertical
                permissionsStack.alignment = .width
                permissionsStack.spacing = 10
                section.addArrangedSubview(permissionsStack)
                permissionsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
                renderPermissionRows()

                section.addArrangedSubview(makeSmallButton("Recheck Permissions", action: #selector(recheckPermissions)))
                section.addArrangedSubview(makeHelpLabel(
                    "After an app update, macOS may keep stale permission entries. If Companion stops working, remove and re-add it in each privacy list, then relaunch."
                ))
            }
        }
    }

    private func makePane(build: (NSStackView) -> Void) -> NSView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let container = FlippedPaneDocumentView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 16
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        build(stack)
        return scrollView
    }

    private func addSection(
        _ title: String,
        help: String?,
        to stack: NSStackView,
        build: (NSStackView) -> Void
    ) {
        let box = NSBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.fillColor = .controlBackgroundColor

        let section = NSStackView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        box.addSubview(section)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .left
        section.addArrangedSubview(titleLabel)

        if let help {
            section.addArrangedSubview(makeHelpLabel(help))
        }

        build(section)

        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            section.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            section.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            section.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
    }

    private func makeSettingsRow(label: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill

        row.addArrangedSubview(makeRowLabel(label))
        row.addArrangedSubview(control)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true

        return row
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func makeHelpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .left
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
        return label
    }

    private func makeInfoRow(label: String, value: String) -> NSStackView {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        return makeSettingsRow(label: label, control: valueLabel)
    }

    private func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private func makeTextField(value: String, placeholder: String, monospaced: Bool) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.stringValue = value
        field.placeholderString = placeholder
        field.font = monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        return field
    }

    private func makeSecureField(value: String, placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: .zero)
        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        return field
    }

    private func makeSmallButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func makeLinkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .linkColor
        button.alignment = .left
        button.setButtonType(.momentaryChange)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func makeProviderPopup(selected: UserSettings.Provider) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for provider in UserSettings.Provider.allCases {
            popup.addItem(withTitle: provider.label)
        }
        popup.selectItem(withTitle: selected.label)
        return popup
    }

    private func makeRoutePopup(selectedRouteID: String?) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        populateRoutePopup(popup, selectedRouteID: selectedRouteID)
        return popup
    }

    private func populateRoutePopup(_ popup: NSPopUpButton?, selectedRouteID: String?) {
        guard let popup else { return }
        popup.removeAllItems()
        let routes = UserSettings.shared.availableModelRoutes
        guard !routes.isEmpty else {
            popup.addItem(withTitle: "- no available models -")
            popup.lastItem?.isEnabled = false
            return
        }

        for route in routes {
            popup.addItem(withTitle: route.menuTitle)
            popup.lastItem?.representedObject = route.id
        }

        if let selectedRouteID,
           let index = routes.firstIndex(where: { $0.id == selectedRouteID }) {
            popup.selectItem(at: index)
        } else if let selectedRouteID,
                  let route = UserSettings.shared.modelRoute(for: selectedRouteID) {
            popup.addItem(withTitle: "\(route.menuTitle) (missing key)")
            popup.lastItem?.representedObject = route.id
            popup.lastItem?.isEnabled = false
            popup.selectItem(at: popup.numberOfItems - 1)
        }
    }

    private func selectedRouteID(from popup: NSPopUpButton?) -> String? {
        popup?.selectedItem?.representedObject as? String
    }

    private func refreshRoutePopups() {
        populateRoutePopup(customPromptRoutePopup, selectedRouteID: UserSettings.shared.customPromptRouteID)
        let selectedActionRouteID = actions.indices.contains(selectedActionIndex)
            ? actions[selectedActionIndex].routeID
            : nil
        populateRoutePopup(actionRoutePopup, selectedRouteID: selectedActionRouteID)
    }

    private func renderPermissionRows() {
        permissionsStack.arrangedSubviews.forEach { view in
            permissionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        permissionsStack.addArrangedSubview(makePermissionRow(
            granted: AXIsProcessTrusted(),
            name: "Accessibility",
            detail: "Lets Companion copy selected text and paste the replacement.",
            action: #selector(openAccessibilitySettings)
        ))

        permissionsStack.addArrangedSubview(makePermissionRow(
            granted: Self.checkInputMonitoring(),
            name: "Input Monitoring",
            detail: "Lets the global shortcut work while another app is focused.",
            action: #selector(openInputMonitoringSettings)
        ))
    }

    private func makePermissionRow(granted: Bool, name: String, detail: String, action: Selector) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        icon.contentTintColor = granted ? .systemGreen : .systemOrange
        row.addSubview(icon)

        let textStack = NSStackView()
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        row.addSubview(textStack)

        let title = NSTextField(labelWithString: granted ? "\(name): Granted" : "\(name): Needs attention")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        textStack.addArrangedSubview(title)

        let detailLabel = makeHelpLabel(detail)
        textStack.addArrangedSubview(detailLabel)

        let button = makeSmallButton("Open System Settings", action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = granted
        row.addSubview(button)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            textStack.topAnchor.constraint(equalTo: row.topAnchor),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            button.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    static func checkInputMonitoring() -> Bool {
        // Try to create a passive event tap. It returns nil when Input Monitoring is not granted.
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        let granted = tap != nil
        if let tap {
            CFMachPortInvalidate(tap)
        }
        return granted
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheckPermissions() {
        renderPermissionRows()
    }

    @objc private func openCreatorWebsite() {
        guard let url = URL(string: "https://santiagoalonso.com") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyHistoryResult() {
        let row = historyTable.selectedRow
        guard historyEntries.indices.contains(row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyEntries[row].result, forType: .string)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear generated text history?"
        alert.informativeText = "This deletes all saved Companion history entries from this Mac. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GenerationHistoryStore.shared.clear()
        reloadHistory(selectFirst: false)
    }

    private func reloadHistory(selectFirst: Bool) {
        guard historyTable != nil else { return }
        historyEntries = GenerationHistoryStore.shared.entries()
        historyTable.reloadData()
        if selectFirst, !historyEntries.isEmpty {
            historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHistoryDetail()
    }

    private func updateHistoryDetail() {
        guard historyResultView != nil, historyMetadataLabel != nil else { return }
        let row = historyTable.selectedRow
        guard historyEntries.indices.contains(row) else {
            historyResultView.string = ""
            historyMetadataLabel.stringValue = historyEntries.isEmpty
                ? "No generated text has been saved yet."
                : "Select a history entry."
            copyHistoryButton?.isEnabled = false
            return
        }

        let entry = historyEntries[row]
        historyResultView.string = entry.result
        let date = Self.historyDateFormatter.string(from: entry.createdAt)
        let imageText = entry.hadImages
            ? " · images: \(entry.imageFileNames.joined(separator: ", "))"
            : ""
        historyMetadataLabel.stringValue = "\(date) · \(entry.actionLabel) · \(entry.provider) · \(entry.model) · \(entry.selectedWordCount) selected words\(imageText)"
        copyHistoryButton?.isEnabled = true
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @objc private func refreshRemoteModels() {
        Task { @MainActor in
            await self.loadRemoteModelCatalog()
        }
    }

    @MainActor
    private func loadRemoteModelCatalog() async {
        refreshRemoteModelsButton.isEnabled = false
        remoteCatalogStatusLabel.stringValue = "Loading OpenRouter models..."
        remoteCatalogStatusLabel.textColor = .tertiaryLabelColor

        do {
            let models = try await OpenRouterModelsAPI.shared.listModels()
            UserSettings.shared.remoteCatalogModels = models
            remoteCatalogModels = models
            refreshRemoteCatalogTable()
            remoteCatalogStatusLabel.stringValue = "Loaded \(models.count) OpenRouter text model\(models.count == 1 ? "" : "s")."
            remoteCatalogStatusLabel.textColor = .systemGreen
        } catch {
            remoteCatalogModels = UserSettings.shared.remoteCatalogModels
            refreshRemoteCatalogTable()
            remoteCatalogStatusLabel.stringValue = "Could not refresh OpenRouter models. Using the saved catalog."
            remoteCatalogStatusLabel.textColor = .systemOrange
        }

        refreshRemoteModelsButton.isEnabled = true
    }

    private func refreshRemoteCatalogTable() {
        guard remoteCatalogTable != nil else { return }

        visibleRemoteCatalogModels = filteredRemoteCatalogModels()
        remoteCatalogTable.reloadData()
        updateRemoteCatalogStatus()
    }

    private func filteredRemoteCatalogModels() -> [UserSettings.RemoteCatalogModel] {
        let query = remoteCatalogFilterField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let models: [UserSettings.RemoteCatalogModel]
        if query.isEmpty {
            models = remoteCatalogModels
        } else {
            models = remoteCatalogModels.filter { model in
                model.id.lowercased().contains(query)
                    || model.displayTitle.lowercased().contains(query)
            }
        }

        return models.sorted { lhs, rhs in
            let lhsEnabled = isRemoteModelEnabled(lhs)
            let rhsEnabled = isRemoteModelEnabled(rhs)
            if lhsEnabled != rhsEnabled {
                return lhsEnabled
            }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func updateRemoteCatalogStatus() {
        guard remoteCatalogStatusLabel != nil else { return }

        let shown = visibleRemoteCatalogModels.count
        let total = remoteCatalogModels.count
        let enabled = modelRoutes.count

        if shown == 0 {
            remoteCatalogStatusLabel.stringValue = "No OpenRouter models match that filter."
            remoteCatalogStatusLabel.textColor = .systemOrange
        } else {
            remoteCatalogStatusLabel.stringValue = "\(enabled) enabled. Showing \(shown) of \(total) saved OpenRouter models. Click Refresh to update the catalog."
            remoteCatalogStatusLabel.textColor = .tertiaryLabelColor
        }
    }

    private func routeID(for catalogModel: UserSettings.RemoteCatalogModel) -> String {
        UserSettings.ModelRoute.makeID(provider: .fal, model: catalogModel.routeModel)
    }

    private func isRemoteModelEnabled(_ catalogModel: UserSettings.RemoteCatalogModel) -> Bool {
        modelRoutes.contains { $0.id == routeID(for: catalogModel) }
    }

    @objc private func toggleRemoteCatalogModel(_ sender: NSButton) {
        let row = sender.tag
        guard visibleRemoteCatalogModels.indices.contains(row) else { return }

        let catalogModel = visibleRemoteCatalogModels[row]
        let id = routeID(for: catalogModel)

        if sender.state == .on {
            guard !modelRoutes.contains(where: { $0.id == id }) else { return }
            modelRoutes.append(UserSettings.ModelRoute(
                id: id,
                name: catalogModel.displayTitle,
                provider: .fal,
                model: catalogModel.routeModel,
                supportsImages: catalogModel.supportsImages
            ))
        } else if modelRoutes.count > 1 {
            modelRoutes.removeAll { $0.id == id }
        } else {
            sender.state = .on
            NSSound.beep()
            return
        }

        saveModelRoutes()
        remoteCatalogTable.reloadData()
        updateRemoteCatalogStatus()
    }

    private func saveModelRoutes() {
        UserSettings.shared.configuredModelRoutes = modelRoutes
        modelRoutes = UserSettings.shared.configuredModelRoutes
        refreshRoutePopups()
    }

    @objc private func falAPIKeyChanged() {
        UserSettings.shared.falAPIKey = falAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func openAIAPIKeyChanged() {
        UserSettings.shared.openAIAPIKey = openAIAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func openAIModelChanged() {
        UserSettings.shared.openAIModel = openAIModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func claudeAPIKeyChanged() {
        UserSettings.shared.apiKey = claudeAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func claudeModelChanged() {
        UserSettings.shared.claudeModel = claudeModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func deepSeekAPIKeyChanged() {
        UserSettings.shared.deepSeekAPIKey = deepSeekAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func deepSeekModelChanged() {
        UserSettings.shared.deepSeekModel = deepSeekModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshRoutePopups()
    }

    @objc private func lmStudioURLChanged() {
        UserSettings.shared.lmStudioBaseURL = lmStudioURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func lmStudioModelChanged() {
        guard let title = lmStudioModelPopup.selectedItem?.title,
              !title.hasPrefix("-") else { return }
        UserSettings.shared.lmStudioModel = title
        updateLMStudioVisionCheckbox(for: title)
        refreshRoutePopups()
    }

    @objc private func toggleLMStudioVision() {
        guard let title = lmStudioModelPopup.selectedItem?.title,
              !title.hasPrefix("-") else { return }
        UserSettings.shared.setLocalModel(title, supportsImages: lmStudioVisionCheckbox.state == .on)
        refreshRoutePopups()
    }

    @objc private func refreshModels() {
        Task { @MainActor in
            await self.loadModelsList(isInitialLoad: false)
        }
    }

    @MainActor
    private func loadModelsList(isInitialLoad: Bool) async {
        if !isInitialLoad {
            lmStudioStatusLabel.stringValue = "Loading models..."
            lmStudioStatusLabel.textColor = .tertiaryLabelColor
            refreshModelsButton.isEnabled = false
        }

        do {
            let models = try await LMStudioAPI.shared.listModels()
            UserSettings.shared.lmStudioKnownModels = models
            lmStudioModelPopup.removeAllItems()

            if models.isEmpty {
                lmStudioModelPopup.addItem(withTitle: "- no models loaded -")
                updateLMStudioVisionCheckbox(for: nil)
                lmStudioStatusLabel.stringValue = "LM Studio is running but no chat models are loaded."
                lmStudioStatusLabel.textColor = .systemOrange
            } else {
                for model in models {
                    lmStudioModelPopup.addItem(withTitle: model)
                }
                let saved = UserSettings.shared.lmStudioModel
                if !saved.isEmpty, models.contains(saved) {
                    lmStudioModelPopup.selectItem(withTitle: saved)
                    updateLMStudioVisionCheckbox(for: saved)
                } else if let first = models.first {
                    lmStudioModelPopup.selectItem(withTitle: first)
                    UserSettings.shared.lmStudioModel = first
                    updateLMStudioVisionCheckbox(for: first)
                }
                lmStudioStatusLabel.stringValue = "Connected. \(models.count) model\(models.count == 1 ? "" : "s") available."
                lmStudioStatusLabel.textColor = .systemGreen
            }
        } catch {
            lmStudioModelPopup.removeAllItems()
            lmStudioModelPopup.addItem(withTitle: "- not connected -")
            updateLMStudioVisionCheckbox(for: nil)
            lmStudioStatusLabel.stringValue = isInitialLoad
                ? "LM Studio not reachable. Start the server and click Refresh."
                : "Could not reach LM Studio at that URL."
            lmStudioStatusLabel.textColor = isInitialLoad ? .tertiaryLabelColor : .systemRed
        }

        refreshModelsButton.isEnabled = true
        refreshRoutePopups()
    }

    private func updateLMStudioVisionCheckbox(for model: String? = nil) {
        let selected = model ?? lmStudioModelPopup.selectedItem?.title ?? UserSettings.shared.lmStudioModel
        let isRealModel = !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selected.hasPrefix("-")
        lmStudioVisionCheckbox?.isEnabled = isRealModel
        lmStudioVisionCheckbox?.state = isRealModel && UserSettings.shared.localModelSupportsImages(selected)
            ? .on
            : .off
    }

    @objc private func customPromptRouteChanged() {
        guard let routeID = selectedRouteID(from: customPromptRoutePopup),
              let route = UserSettings.shared.modelRoute(for: routeID) else { return }
        UserSettings.shared.customPromptRouteID = routeID
        UserSettings.shared.customPromptProvider = route.provider
    }

    @objc private func toggleFallback() {
        UserSettings.shared.fallbackToClaude = fallbackCheckbox.state == .on
    }

    @objc private func actionChanged() {
        saveCurrentAction()
        selectedActionIndex = actionPopup.indexOfSelectedItem
        refreshActionEditor()
    }

    @objc private func actionNameChanged() {
        guard actions.indices.contains(selectedActionIndex) else { return }
        let name = actionNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        actions[selectedActionIndex].name = name.isEmpty ? "Untitled Action" : name
        saveActions()
        refreshActionPopup()
    }

    @objc private func actionRouteChanged() {
        guard actions.indices.contains(selectedActionIndex) else { return }
        guard let routeID = selectedRouteID(from: actionRoutePopup),
              let route = UserSettings.shared.modelRoute(for: routeID) else { return }
        actions[selectedActionIndex].routeID = routeID
        actions[selectedActionIndex].provider = route.provider
        saveActions()
    }

    @objc private func addAction() {
        saveCurrentAction()
        let action = UserSettings.SavedAction(
            id: UUID().uuidString,
            name: "New Action",
            prompt: "Rewrite the selected text. Return only the rewritten text.",
            provider: UserSettings.shared.customPromptProvider,
            symbolName: "wand.and.stars",
            routeID: UserSettings.shared.customPromptRouteID
        )
        actions.append(action)
        selectedActionIndex = actions.count - 1
        saveActions()
        refreshActionEditor()
    }

    @objc private func removeAction() {
        guard actions.count > 1, actions.indices.contains(selectedActionIndex) else { return }
        actions.remove(at: selectedActionIndex)
        selectedActionIndex = min(selectedActionIndex, actions.count - 1)
        saveActions()
        refreshActionEditor()
    }

    @objc private func moveActionUp() {
        guard selectedActionIndex > 0, actions.indices.contains(selectedActionIndex) else { return }
        saveCurrentAction()
        actions.swapAt(selectedActionIndex, selectedActionIndex - 1)
        selectedActionIndex -= 1
        saveActions()
        refreshActionEditor()
    }

    @objc private func moveActionDown() {
        guard selectedActionIndex < actions.count - 1, actions.indices.contains(selectedActionIndex) else { return }
        saveCurrentAction()
        actions.swapAt(selectedActionIndex, selectedActionIndex + 1)
        selectedActionIndex += 1
        saveActions()
        refreshActionEditor()
    }

    @objc private func resetPrompt() {
        guard actions.indices.contains(selectedActionIndex) else { return }
        let actionID = actions[selectedActionIndex].id
        if let defaultAction = UserSettings.defaultSavedActions.first(where: { $0.id == actionID }) {
            actions[selectedActionIndex].prompt = defaultAction.prompt
            promptField.string = defaultAction.prompt
            saveActions()
        }
    }

    private func refreshActionEditor() {
        if actions.isEmpty {
            actions = UserSettings.defaultSavedActions
        }
        selectedActionIndex = min(max(selectedActionIndex, 0), actions.count - 1)
        refreshActionPopup()

        let action = actions[selectedActionIndex]
        actionNameField.stringValue = action.name
        promptField.string = action.prompt
        populateRoutePopup(actionRoutePopup, selectedRouteID: action.routeID)
    }

    private func refreshActionPopup() {
        actionPopup.removeAllItems()
        for action in actions {
            actionPopup.addItem(withTitle: action.name)
        }
        if actions.indices.contains(selectedActionIndex) {
            actionPopup.selectItem(at: selectedActionIndex)
        }
    }

    private func saveCurrentAction() {
        guard actions.indices.contains(selectedActionIndex) else { return }
        let name = actionNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        actions[selectedActionIndex].name = name.isEmpty ? "Untitled Action" : name
        actions[selectedActionIndex].prompt = promptField.string

        if let routeID = selectedRouteID(from: actionRoutePopup),
           let route = UserSettings.shared.modelRoute(for: routeID) {
            actions[selectedActionIndex].routeID = routeID
            actions[selectedActionIndex].provider = route.provider
        }

        saveActions()
    }

    private func saveActions() {
        UserSettings.shared.savedActions = actions
    }

    @objc private func recordShortcut() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }

        shortcutLabel.stringValue = "Press shortcut..."
        shortcutLabel.textColor = .systemOrange

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !mods.isEmpty else { return event }

            let keyCode = UInt32(event.keyCode)
            HotkeyManager.shared.updateShortcut(keyCode: keyCode, modifiers: mods)

            self.shortcutLabel.stringValue = self.formatShortcut(modifiers: mods, keyCode: event.keyCode)
            self.shortcutLabel.textColor = .labelColor

            if let monitor = self.shortcutMonitor {
                NSEvent.removeMonitor(monitor)
                self.shortcutMonitor = nil
            }

            return nil
        }
    }

    @objc private func resetShortcut() {
        HotkeyManager.shared.resetToDefault()
        shortcutLabel.stringValue = currentShortcutLabel()
        shortcutLabel.textColor = .labelColor
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = launchAtLoginCheckbox.state == .on
        UserSettings.shared.launchAtLogin = enabled

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Failed to update launch at login: \(error)")
            }
        }
    }

    private func currentShortcutLabel() -> String {
        let settings = UserSettings.shared
        guard let keyCode = settings.shortcutKeyCode,
              let modifiers = settings.shortcutModifiers else {
            return "Cmd + Shift + E"
        }
        return formatShortcut(
            modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
            keyCode: UInt16(keyCode)
        )
    }

    private func formatShortcut(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }

        let keyName: String
        switch Int(keyCode) {
        case kVK_ANSI_A: keyName = "A"
        case kVK_ANSI_B: keyName = "B"
        case kVK_ANSI_C: keyName = "C"
        case kVK_ANSI_D: keyName = "D"
        case kVK_ANSI_E: keyName = "E"
        case kVK_ANSI_F: keyName = "F"
        case kVK_ANSI_G: keyName = "G"
        case kVK_ANSI_H: keyName = "H"
        case kVK_ANSI_I: keyName = "I"
        case kVK_ANSI_J: keyName = "J"
        case kVK_ANSI_K: keyName = "K"
        case kVK_ANSI_L: keyName = "L"
        case kVK_ANSI_M: keyName = "M"
        case kVK_ANSI_N: keyName = "N"
        case kVK_ANSI_O: keyName = "O"
        case kVK_ANSI_P: keyName = "P"
        case kVK_ANSI_Q: keyName = "Q"
        case kVK_ANSI_R: keyName = "R"
        case kVK_ANSI_S: keyName = "S"
        case kVK_ANSI_T: keyName = "T"
        case kVK_ANSI_U: keyName = "U"
        case kVK_ANSI_V: keyName = "V"
        case kVK_ANSI_W: keyName = "W"
        case kVK_ANSI_X: keyName = "X"
        case kVK_ANSI_Y: keyName = "Y"
        case kVK_ANSI_Z: keyName = "Z"
        default: keyName = "Key(\(keyCode))"
        }

        parts.append(keyName)
        return parts.joined(separator: " + ")
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
        saveCurrentAction()
    }
}

extension SettingsWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if remoteCatalogTable != nil, tableView === remoteCatalogTable {
            return visibleRemoteCatalogModels.count
        }
        if historyTable != nil, tableView === historyTable {
            return historyEntries.count
        }
        return paneItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if remoteCatalogTable != nil, tableView === remoteCatalogTable {
            guard visibleRemoteCatalogModels.indices.contains(row) else { return nil }
            let model = visibleRemoteCatalogModels[row]
            if tableColumn?.identifier.rawValue == "remoteEnabled" {
                return makeRemoteEnabledCell(model: model, row: row)
            }
            return makeRemoteModelCell(model: model)
        }

        if historyTable != nil, tableView === historyTable {
            guard historyEntries.indices.contains(row) else { return nil }
            return makeHistoryCell(entry: historyEntries[row])
        }

        guard paneItems.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SettingsPaneCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makePaneCell(identifier: identifier)

        let item = paneItems[row]
        cell.textField?.stringValue = item.title
        cell.imageView?.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let tableView = notification.object as? NSTableView,
           remoteCatalogTable != nil,
           tableView === remoteCatalogTable {
            return
        }

        if let tableView = notification.object as? NSTableView,
           historyTable != nil,
           tableView === historyTable {
            updateHistoryDetail()
            return
        }
        showPane(at: sidebarTable.selectedRow)
    }

    private func makeRemoteEnabledCell(model: UserSettings.RemoteCatalogModel, row: Int) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("RemoteEnabledCell")

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRemoteCatalogModel))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.state = isRemoteModelEnabled(model) ? .on : .off
        checkbox.tag = row
        checkbox.toolTip = checkbox.state == .on
            ? "Enabled in Companion"
            : "Enable this model in Companion"
        cell.addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    private func makeRemoteModelCell(model: UserSettings.RemoteCatalogModel) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("RemoteModelCell")

        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        cell.addSubview(row)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let title = NSTextField(labelWithString: model.displayTitle)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(title)

        let slug = NSTextField(labelWithString: model.routeModel)
        slug.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        slug.textColor = .secondaryLabelColor
        slug.lineBreakMode = .byTruncatingMiddle
        textStack.addArrangedSubview(slug)

        row.addArrangedSubview(textStack)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if model.supportsImages {
            let imageBadge = NSTextField(labelWithString: "Images")
            imageBadge.font = .systemFont(ofSize: 10.5, weight: .semibold)
            imageBadge.textColor = .secondaryLabelColor
            imageBadge.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(imageBadge)
        }

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    private func makeHistoryCell(entry: GenerationHistoryStore.Entry) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("HistoryCell")

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        cell.addSubview(stack)

        let title = NSTextField(labelWithString: entry.actionLabel)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(title)

        let date = Self.historyDateFormatter.string(from: entry.createdAt)
        let imageMark = entry.hadImages ? " · images" : ""
        let detail = NSTextField(labelWithString: "\(date) · \(entry.provider) · \(entry.model)\(imageMark)")
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(detail)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    private func makePaneCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 13, weight: .medium)
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

extension SettingsWindow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard actions.indices.contains(selectedActionIndex) else { return }
        actions[selectedActionIndex].prompt = promptField.string
        saveActions()
    }
}

extension SettingsWindow: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }

        if field === falAPIKeyField {
            falAPIKeyChanged()
        } else if field === openAIAPIKeyField {
            openAIAPIKeyChanged()
        } else if field === openAIModelField {
            openAIModelChanged()
        } else if field === claudeAPIKeyField {
            claudeAPIKeyChanged()
        } else if field === claudeModelField {
            claudeModelChanged()
        } else if field === deepSeekAPIKeyField {
            deepSeekAPIKeyChanged()
        } else if field === deepSeekModelField {
            deepSeekModelChanged()
        } else if field === remoteCatalogFilterField {
            refreshRemoteCatalogTable()
        } else if field === lmStudioURLField {
            lmStudioURLChanged()
        } else if field === actionNameField {
            actionNameChanged()
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
