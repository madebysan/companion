import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = CommandPaletteWindowController()

    private let paletteWidth: CGFloat = 430
    private let previewWidth: CGFloat = 720
    private let previewHeight: CGFloat = 360
    private let rowHeight: CGFloat = 38
    private let inputHeight: CGFloat = 52
    private let trayTopGap: CGFloat = 6
    private let trayInset: CGFloat = 5
    private let hintHeight: CGFloat = 0
    private let statusHeight: CGFloat = 58
    private let compactLoadingWidth: CGFloat = 64
    private let compactLoadingHeight: CGFloat = 34
    private let maxVisibleRows = 5
    private let maxImages = 4
    private let maxImageBytes = 10 * 1024 * 1024

    private enum PaletteRow {
        case custom(String)
        case action(UserSettings.SavedAction)
    }

    private enum PaletteMode {
        case input
        case loading
        case result
    }

    private enum AttachmentError: LocalizedError {
        case unsupported(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\(name) is not supported. Use PNG, JPEG, GIF, or WebP."
            case .tooLarge(let name):
                return "\(name) is larger than 10 MB."
            }
        }
    }

    private var selectedText = ""
    private var allActions: [UserSettings.SavedAction] = []
    private var visibleActions: [UserSettings.SavedAction] = []
    private var visibleRows: [PaletteRow] = []
    private var selectedIndex = 0
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var shouldDismissOnDeactivate = true
    private var shouldDismissOnOutsideClick = true
    private var routeSelection: GenerationRoute = .auto
    private var routeOptions: [GenerationRoute] = []
    private var imageAttachments: [PromptImageAttachment] = []
    private var paletteWarning: String?
    private var previewResultText = ""
    private var paletteMode: PaletteMode = .input

    private var rootStack: NSStackView!
    private var inputField: PaletteTextField!
    private var routePopup: NSPopUpButton!
    private var attachmentStack: NSStackView!
    private var warningLabel: NSTextField!
    private var inputHeightConstraint: NSLayoutConstraint!
    private var resultsContainer: DraggableVisualEffectView!
    private var rowsStack: NSStackView!
    private var hintLabel: NSTextField!
    private var statusTitle: NSTextField!
    private var statusSubtitle: NSTextField!
    private var spinner: NSProgressIndicator!

    var isPaletteVisible: Bool {
        window?.isVisible == true
    }

    convenience init() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 286),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        self.init(window: panel)
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        setupUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(selectedText: String, anchorRect: CGRect? = nil) {
        self.selectedText = selectedText
        routeSelection = .auto
        routeOptions = [.auto] + UserSettings.shared.availableModelRoutes.map { .model($0) }
        imageAttachments = []
        paletteWarning = nil
        allActions = UserSettings.shared.savedActions
        visibleActions = allActions
        visibleRows = visibleActions.map { .action($0) }
        selectedIndex = visibleRows.isEmpty ? -1 : 0

        renderInputState(preservingQuery: false)
        position(anchorRect: anchorRect)

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeKey()
        focusInputField()
        installKeyMonitor()
        installOutsideClickMonitor()
    }

    func showRunning(title: String, subtitle: String = "Replacing selected text") {
        renderPreviewState(title: title, subtitle: subtitle, text: nil, images: [], isLoading: true)
    }

    func showSuccess(subtitle: String = "Selection replaced") {
        renderStatusState(
            title: "Done",
            subtitle: subtitle,
            isError: false,
            isSuccess: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.closePalette()
        }
    }

    func showImageResult(text: String, images: [PromptImageAttachment], subtitle: String) {
        renderPreviewState(title: "Image answer", subtitle: subtitle, text: text, images: images, isLoading: false)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeKey()
        installKeyMonitor()
        installOutsideClickMonitor()
    }

    func showTextResult(text: String, title: String, subtitle: String, images: [PromptImageAttachment] = []) {
        renderPreviewState(title: title, subtitle: subtitle, text: text, images: images, isLoading: false)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeKey()
        installKeyMonitor()
        installOutsideClickMonitor()
    }

    func showError(_ message: String) {
        renderStatusState(
            title: "Companion failed",
            subtitle: message,
            isError: true,
            isSuccess: false
        )
    }

    func showPreviewInstruction(_ instruction: String) {
        guard inputField != nil else { return }
        inputField.stringValue = instruction
        selectedIndex = 0
        updateVisibleRows()
        focusInputField()
    }

    func dismissAfterPreviewAction() {
        closePalette()
    }

    override func close() {
        TextGrabber.shared.cancelPaletteSession()
        closePalette()
    }

    @objc private func appDidResignActive() {
        guard shouldDismissOnDeactivate, isPaletteVisible else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard !isMouseInsidePalette() else { return }
        close()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = trayTopGap
        rootStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        renderInputState()
    }

    private func makeGlassSurface(
        material _: NSVisualEffectView.Material,
        radius: CGFloat,
        borderAlpha: CGFloat,
        shadowOpacity: Float = 0.14,
        shadowRadius: CGFloat = 16
    ) -> DraggableVisualEffectView {
        let surface = DraggableVisualEffectView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.material = .contentBackground
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = radius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 0.8
        surface.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(max(borderAlpha, 0.22)).cgColor
        surface.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        surface.layer?.shadowColor = NSColor.black.cgColor
        surface.layer?.shadowOpacity = shadowOpacity
        surface.layer?.shadowRadius = shadowRadius
        surface.layer?.shadowOffset = CGSize(width: 0, height: -7)
        return surface
    }

    private func renderInputState(preservingQuery: Bool = true) {
        let currentQuery = preservingQuery ? (inputField?.stringValue ?? "") : ""
        paletteMode = .input
        shouldDismissOnDeactivate = true
        shouldDismissOnOutsideClick = true
        clearRootStack()
        rootStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let inputContainer = makeGlassSurface(
            material: .menu,
            radius: 17,
            borderAlpha: 0.24,
            shadowOpacity: 0.13,
            shadowRadius: 15
        )
        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.onFileDrop = { [weak self] urls in
            self?.handleDroppedURLs(urls)
        }
        rootStack.addArrangedSubview(inputContainer)

        let surfaceStack = NSStackView()
        surfaceStack.translatesAutoresizingMaskIntoConstraints = false
        surfaceStack.orientation = .vertical
        surfaceStack.spacing = 5
        surfaceStack.alignment = .width
        inputContainer.addSubview(surfaceStack)

        let inputStack = NSStackView()
        inputStack.translatesAutoresizingMaskIntoConstraints = false
        inputStack.orientation = .horizontal
        inputStack.spacing = 9
        inputStack.alignment = .centerY
        surfaceStack.addArrangedSubview(inputStack)

        inputField = PaletteTextField(frame: .zero)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholderString = inputPlaceholder()
        inputField.stringValue = currentQuery
        inputField.font = .systemFont(ofSize: 16, weight: .regular)
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.maximumNumberOfLines = 1
        inputField.lineBreakMode = .byTruncatingHead
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(runSelected)
        inputField.onFileDrop = { [weak self] urls in
            self?.handleDroppedURLs(urls)
        }
        inputField.onCommandNumberShortcut = { [weak self] index in
            guard let self,
                  self.paletteMode == .input,
                  self.inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  self.visibleRows.indices.contains(index) else {
                return false
            }
            self.selectedIndex = index
            self.runRow(self.visibleRows[index])
            return true
        }
        configureSingleLineField(inputField)
        inputStack.addArrangedSubview(inputField)
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        routePopup = NSPopUpButton(frame: .zero, pullsDown: true)
        routePopup.translatesAutoresizingMaskIntoConstraints = false
        routePopup.isBordered = false
        routePopup.font = .systemFont(ofSize: 10.5, weight: .semibold)
        routePopup.contentTintColor = NSColor(calibratedWhite: 0.28, alpha: 1)
        applyKeyCapChrome(to: routePopup)
        routePopup.target = self
        routePopup.action = #selector(routeChanged)
        configureRoutePopup()
        inputStack.addArrangedSubview(routePopup)
        routePopup.setContentHuggingPriority(.required, for: .horizontal)
        routePopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let settingsImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Open Settings")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))

        let settingsButtonContainer = NSView()
        settingsButtonContainer.translatesAutoresizingMaskIntoConstraints = false
        settingsButtonContainer.toolTip = "Open Settings"
        applyKeyCapChrome(to: settingsButtonContainer)

        let settingsButton = NSButton(
            image: settingsImage ?? NSImage(),
            target: self,
            action: #selector(openSettingsFromPalette)
        )
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.imagePosition = .imageOnly
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.contentTintColor = NSColor(calibratedWhite: 0.28, alpha: 1)
        settingsButton.focusRingType = .none
        settingsButton.toolTip = "Open Settings"
        settingsButtonContainer.addSubview(settingsButton)
        inputStack.addArrangedSubview(settingsButtonContainer)
        settingsButtonContainer.setContentHuggingPriority(.required, for: .horizontal)
        settingsButtonContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            settingsButtonContainer.widthAnchor.constraint(equalToConstant: 30),
            settingsButtonContainer.heightAnchor.constraint(equalTo: routePopup.heightAnchor),
            settingsButton.topAnchor.constraint(equalTo: settingsButtonContainer.topAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: settingsButtonContainer.leadingAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: settingsButtonContainer.trailingAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: settingsButtonContainer.bottomAnchor),
        ])

        if let snippet = selectedTextSnippet() {
            let preview = NSView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 10
            preview.layer?.cornerCurve = .continuous
            preview.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            surfaceStack.addArrangedSubview(preview)

            let previewStack = NSStackView()
            previewStack.translatesAutoresizingMaskIntoConstraints = false
            previewStack.orientation = .horizontal
            previewStack.alignment = .centerY
            previewStack.spacing = 8
            preview.addSubview(previewStack)

            let text = NSTextField(labelWithString: snippet)
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byTruncatingTail
            previewStack.addArrangedSubview(text)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            if let summary = selectionSummary() {
                let count = NSTextField(labelWithString: summary)
                count.font = .systemFont(ofSize: 10, weight: .semibold)
                count.textColor = .tertiaryLabelColor
                previewStack.addArrangedSubview(count)
                count.setContentHuggingPriority(.required, for: .horizontal)
            }

            NSLayoutConstraint.activate([
                preview.heightAnchor.constraint(equalToConstant: 28),
                previewStack.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 10),
                previewStack.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -10),
                previewStack.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            ])
        }

        attachmentStack = NSStackView()
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentStack.orientation = .horizontal
        attachmentStack.spacing = 6
        attachmentStack.alignment = .centerY
        attachmentStack.isHidden = imageAttachments.isEmpty
        surfaceStack.addArrangedSubview(attachmentStack)
        renderAttachmentChips()

        warningLabel = NSTextField(labelWithString: paletteWarning ?? "")
        warningLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byTruncatingTail
        warningLabel.isHidden = paletteWarning == nil
        surfaceStack.addArrangedSubview(warningLabel)

        inputHeightConstraint = inputContainer.heightAnchor.constraint(equalToConstant: currentInputHeight())
        NSLayoutConstraint.activate([
            inputHeightConstraint,
            inputContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            surfaceStack.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 7),
            surfaceStack.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 16),
            surfaceStack.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -12),
            surfaceStack.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -7),
            inputStack.heightAnchor.constraint(equalToConstant: 32),
            routePopup.heightAnchor.constraint(equalToConstant: 24),
            routePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
            routePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 92),
        ])

        resultsContainer = makeGlassSurface(
            material: .menu,
            radius: 15,
            borderAlpha: 0.14,
            shadowOpacity: 0.09,
            shadowRadius: 13
        )
        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.onFileDrop = { [weak self] urls in
            self?.handleDroppedURLs(urls)
        }
        rootStack.addArrangedSubview(resultsContainer)
        resultsContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let trayStack = NSStackView()
        trayStack.translatesAutoresizingMaskIntoConstraints = false
        trayStack.orientation = .vertical
        trayStack.alignment = .width
        trayStack.spacing = 1
        resultsContainer.addSubview(trayStack)

        rowsStack = NSStackView()
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 1
        trayStack.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: trayStack.widthAnchor).isActive = true

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 8.5, weight: .medium)
        hintLabel.textColor = .quaternaryLabelColor
        hintLabel.alignment = .right
        trayStack.addArrangedSubview(hintLabel)
        hintLabel.isHidden = true
        hintLabel.heightAnchor.constraint(equalToConstant: hintHeight).isActive = true

        NSLayoutConstraint.activate([
            trayStack.topAnchor.constraint(equalTo: resultsContainer.topAnchor, constant: trayInset),
            trayStack.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor, constant: trayInset),
            trayStack.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor, constant: -trayInset),
            trayStack.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor, constant: -trayInset),
        ])

        updateVisibleRows()
    }

    private func currentInputHeight() -> CGFloat {
        var height = inputHeight
        if selectedTextSnippet() != nil {
            height += 33
        }
        if !imageAttachments.isEmpty {
            height += 25
        }
        if paletteWarning != nil {
            height += 17
        }
        return height
    }

    private func configureRoutePopup() {
        routePopup.removeAllItems()
        routePopup.addItem(withTitle: routeButtonTitle())
        for route in routeOptions {
            routePopup.addItem(withTitle: route.menuTitle())
        }
        routePopup.selectItem(at: 0)
        routePopup.toolTip = "Override the provider for this run"
        routePopup.isBordered = false
        routePopup.controlSize = .small
        applyKeyCapChrome(to: routePopup)
    }

    private func routeButtonTitle() -> String {
        switch routeSelection {
        case .auto:
            return "Auto"
        case .model:
            return "Route"
        }
    }

    private func renderAttachmentChips() {
        attachmentStack.arrangedSubviews.forEach { view in
            attachmentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, attachment) in imageAttachments.enumerated() {
            attachmentStack.addArrangedSubview(makeAttachmentChip(attachment, index: index))
        }
    }

    private func makeAttachmentChip(_ attachment: PromptImageAttachment, index: Int) -> NSView {
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 9
        chip.layer?.cornerCurve = .continuous
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        chip.addSubview(stack)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(icon)
        icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let label = NSTextField(labelWithString: attachment.fileName)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 108).isActive = true

        let remove = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove attachment") ?? NSImage(),
            target: self,
            action: #selector(removeAttachment(_:))
        )
        remove.tag = index
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.imageScaling = .scaleProportionallyDown
        remove.contentTintColor = .secondaryLabelColor
        remove.focusRingType = .none
        remove.toolTip = "Remove image"
        stack.addArrangedSubview(remove)
        remove.widthAnchor.constraint(equalToConstant: 13).isActive = true
        remove.heightAnchor.constraint(equalToConstant: 13).isActive = true

        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 19),
            stack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            stack.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])

        return chip
    }

    private func renderStatusState(title: String, subtitle: String, isError: Bool, isSuccess: Bool) {
        shouldDismissOnDeactivate = isError || isSuccess
        shouldDismissOnOutsideClick = true
        clearRootStack()
        rootStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        if !isError && !isSuccess {
            renderCompactLoadingState()
            return
        }

        let statusContainer = makeGlassSurface(material: .menu, radius: 17, borderAlpha: 0.22)
        rootStack.addArrangedSubview(statusContainer)
        statusContainer.heightAnchor.constraint(equalToConstant: statusHeight).isActive = true
        statusContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        statusContainer.addSubview(stack)

        let statusIcon = NSImageView()
        statusIcon.image = NSImage(
            systemSymbolName: isError ? "exclamationmark.triangle" : "checkmark.circle",
            accessibilityDescription: nil
        )
        statusIcon.contentTintColor = isError ? .systemRed : .systemGreen
        stack.addArrangedSubview(statusIcon)
        statusIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        stack.addArrangedSubview(textStack)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusTitle = NSTextField(labelWithString: title)
        statusTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        statusTitle.textColor = .labelColor
        statusTitle.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(statusTitle)
        statusTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusSubtitle = NSTextField(wrappingLabelWithString: subtitle)
        statusSubtitle.font = .systemFont(ofSize: 12, weight: .regular)
        statusSubtitle.textColor = .secondaryLabelColor
        statusSubtitle.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(statusSubtitle)
        statusSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -16),
        ])
        resizeToSize(width: paletteWidth, height: statusHeight)
    }

    private func renderCompactLoadingState() {
        shouldDismissOnDeactivate = false
        shouldDismissOnOutsideClick = true
        let container = makeGlassSurface(
            material: .menu,
            radius: 17,
            borderAlpha: 0.2,
            shadowOpacity: 0.12,
            shadowRadius: 12
        )
        rootStack.addArrangedSubview(container)
        container.heightAnchor.constraint(equalToConstant: compactLoadingHeight).isActive = true
        container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        container.addSubview(stack)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let cancelButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") ?? NSImage(),
            target: self,
            action: #selector(cancelRunningRequest)
        )
        cancelButton.isBordered = false
        cancelButton.imagePosition = .imageOnly
        cancelButton.imageScaling = .scaleProportionallyDown
        cancelButton.contentTintColor = .labelColor
        cancelButton.focusRingType = .none
        cancelButton.toolTip = "Cancel this request"
        stack.addArrangedSubview(cancelButton)
        cancelButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        cancelButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        resizeToSize(width: compactLoadingWidth, height: compactLoadingHeight)
    }

    private func renderPreviewState(
        title: String,
        subtitle: String,
        text: String?,
        images: [PromptImageAttachment],
        isLoading: Bool
    ) {
        paletteMode = isLoading ? .loading : .result
        previewResultText = text ?? ""
        shouldDismissOnDeactivate = false
        shouldDismissOnOutsideClick = false
        clearRootStack()
        rootStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let resultContainer = makeGlassSurface(
            material: .menu,
            radius: 18,
            borderAlpha: 0.22,
            shadowOpacity: 0.13,
            shadowRadius: 16
        )
        rootStack.addArrangedSubview(resultContainer)
        resultContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        resultContainer.heightAnchor.constraint(equalToConstant: previewHeight).isActive = true

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        resultContainer.addSubview(stack)

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        stack.addArrangedSubview(header)
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true

        if !images.isEmpty {
            let imageStrip = makePreviewImageStrip(images)
            header.addArrangedSubview(imageStrip)
        }

        let pill = makeActionPill(title)
        header.addArrangedSubview(pill)

        if !subtitle.isEmpty {
            let detail = NSTextField(labelWithString: subtitle)
            detail.font = .systemFont(ofSize: 11, weight: .medium)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            header.addArrangedSubview(detail)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
            target: self,
            action: #selector(closePreview)
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.focusRingType = .none
        closeButton.toolTip = "Close"
        header.addArrangedSubview(closeButton)
        closeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)

        if isLoading {
            stack.addArrangedSubview(makeSkeletonPreview())
        } else {
            stack.addArrangedSubview(makeResultTextView(text ?? ""))
        }

        let footer = makePreviewFooter(isLoading: isLoading)
        stack.addArrangedSubview(footer)
        footer.heightAnchor.constraint(equalToConstant: 48).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: resultContainer.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor, constant: -12),
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18),
        ])

        resizeToSize(width: previewWidth, height: previewHeight)
    }

    private func makeActionPill(_ title: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 12
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.55).cgColor
        pill.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.07).cgColor

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .systemTeal
        label.lineBreakMode = .byTruncatingTail
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 24),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: 190),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        return pill
    }

    private func makeResultTextView(_ text: String) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.string = text
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scroll.documentView = textView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return scroll
    }

    private func makeSkeletonPreview() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        container.addSubview(stack)

        let widths: [CGFloat] = [620, 530, 585, 470, 560, 390]
        for width in widths {
            let bar = NSView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 8
            bar.layer?.cornerCurve = .continuous
            bar.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.16).cgColor
            stack.addArrangedSubview(bar)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: width),
                bar.heightAnchor.constraint(equalToConstant: 15),
            ])
        }

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
        ])

        return container
    }

    private func makePreviewFooter(isLoading: Bool) -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.borderWidth = 1
        footer.layer?.borderColor = NSColor(calibratedWhite: 0.84, alpha: 0.9).cgColor
        footer.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.98).cgColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        footer.addSubview(stack)

        stack.addArrangedSubview(makeKeyHint(keys: ["esc"], label: "close"))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if isLoading {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
            spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        } else {
            stack.addArrangedSubview(makeKeyHint(keys: ["⌘", "C"], label: "copy"))
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        return footer
    }

    private func makeKeyHint(keys: [String], label: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6

        for key in keys {
            stack.addArrangedSubview(makeKeyCap(key))
        }

        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        stack.addArrangedSubview(text)

        return stack
    }

    private func makeShortcutKeyGroup(_ keys: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)

        for key in keys {
            stack.addArrangedSubview(makeKeyCap(key))
        }

        return stack
    }

    private func makeKeyCap(_ key: String) -> NSView {
        let cap = NSView()
        cap.translatesAutoresizingMaskIntoConstraints = false
        applyKeyCapChrome(to: cap)

        let label = NSTextField(labelWithString: key)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.28, alpha: 1)
        label.alignment = .center
        cap.addSubview(label)

        let minWidth: CGFloat = key.count <= 1 ? 23 : 34
        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: 22),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor, constant: -0.5),
        ])

        return cap
    }

    private func applyKeyCapChrome(to view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 0.72, alpha: 1).cgColor
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
    }

    private func makePreviewImageStrip(_ images: [PromptImageAttachment]) -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 5
        strip.setContentHuggingPriority(.required, for: .horizontal)

        for attachment in images.prefix(3) {
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.wantsLayer = true
            holder.layer?.cornerRadius = 8
            holder.layer?.cornerCurve = .continuous
            holder.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(data: attachment.data) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            holder.addSubview(imageView)

            NSLayoutConstraint.activate([
                holder.widthAnchor.constraint(equalToConstant: 54),
                holder.heightAnchor.constraint(equalToConstant: 42),
                imageView.topAnchor.constraint(equalTo: holder.topAnchor, constant: 3),
                imageView.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 3),
                imageView.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -3),
                imageView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -3),
            ])
            strip.addArrangedSubview(holder)
        }

        if images.count > 3 {
            let more = NSTextField(labelWithString: "+\(images.count - 3)")
            more.font = .systemFont(ofSize: 11, weight: .semibold)
            more.textColor = .secondaryLabelColor
            strip.addArrangedSubview(more)
        }

        return strip
    }

    func controlTextDidChange(_ obj: Notification) {
        if convertDroppedPathTextToAttachments() {
            return
        }
        selectedIndex = 0
        updateVisibleRows()
        refreshRouteWarning()
        scrollInputToEnd()
    }

    @objc private func routeChanged() {
        let index = routePopup.indexOfSelectedItem
        guard index > 0 else {
            configureRoutePopup()
            return
        }
        let routeIndex = index - 1
        guard routeOptions.indices.contains(routeIndex) else { return }
        routeSelection = routeOptions[routeIndex]
        paletteWarning = warningForCurrentRow()
        renderInputState()
        focusInputField()
    }

    @objc private func openSettingsFromPalette() {
        close()
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard imageAttachments.indices.contains(sender.tag) else { return }
        imageAttachments.remove(at: sender.tag)
        paletteWarning = warningForCurrentRow()
        renderInputState()
        focusInputField()
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        var accepted: [PromptImageAttachment] = []
        var rejection: String?

        for url in urls {
            guard imageAttachments.count + accepted.count < maxImages else {
                rejection = "Attach up to \(maxImages) images."
                break
            }

            do {
                accepted.append(try makeImageAttachment(from: url))
            } catch {
                rejection = error.localizedDescription
            }
        }

        if !accepted.isEmpty {
            imageAttachments.append(contentsOf: accepted)
            selectVisionRouteForImagesIfNeeded()
        }

        paletteWarning = rejection ?? warningForCurrentRow()
        renderInputState()
        focusInputField()
    }

    private func convertDroppedPathTextToAttachments() -> Bool {
        let raw = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let urls = imageURLs(fromDroppedText: raw)
        guard !urls.isEmpty else { return false }

        inputField.stringValue = ""
        handleDroppedURLs(urls)
        return true
    }

    private func imageURLs(fromDroppedText text: String) -> [URL] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidates = lines.isEmpty ? [text] : lines
        var urls: [URL] = []

        for candidate in candidates {
            let url: URL
            if candidate.hasPrefix("file://"), let parsed = URL(string: candidate) {
                url = parsed
            } else if candidate.hasPrefix("/") {
                url = URL(fileURLWithPath: candidate)
            } else {
                return []
            }

            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  (try? mimeType(for: url)) != nil else {
                return []
            }
            urls.append(url)
        }

        return urls
    }

    @objc private func runSelected() {
        let instruction = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if visibleRows.indices.contains(selectedIndex) {
            runRow(visibleRows[selectedIndex])
            return
        }

        guard !instruction.isEmpty else { return }
        let row = PaletteRow.custom(instruction)
        guard validateCanRun(row) else { return }
        TextGrabber.shared.runCustomInstruction(
            instruction,
            route: routeSelection,
            images: imageAttachments
        )
    }

    @objc private func cancelRunningRequest() {
        close()
    }

    @objc private func closePreview() {
        close()
    }

    @objc private func copyPreviewResult() {
        guard !TextGrabber.shared.copyPreviewResult(), !previewResultText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(previewResultText, forType: .string)
    }

    @objc private func pastePreviewResult() {
        TextGrabber.shared.pastePreviewResult()
    }

    private func selectVisionRouteForImagesIfNeeded() {
        if case .model(let current) = routeSelection, current.supportsImages {
            return
        }
        guard let visionRoute = UserSettings.shared.availableModelRoutes.first(where: { $0.supportsImages }) else {
            return
        }
        routeSelection = .model(visionRoute)
    }

    private func updateVisibleRows() {
        let query = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            visibleActions = allActions
            visibleRows = imageAttachments.isEmpty
                ? visibleActions.map { .action($0) }
                : [.custom(defaultImageInstruction())] + visibleActions.map { .action($0) }
        } else {
            visibleActions = allActions.filter { action in
                action.name.localizedCaseInsensitiveContains(query)
            }
            visibleRows = [.custom(query)] + visibleActions.map { .action($0) }
        }
        selectedIndex = visibleRows.isEmpty ? -1 : min(max(selectedIndex, 0), visibleRows.count - 1)
        renderRows(query: query)
        resizeToFit(rowCount: min(visibleRows.count, maxVisibleRows))
    }

    private func renderRows(query: String) {
        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let startIndex = min(
            max(selectedIndex - maxVisibleRows + 1, 0),
            max(visibleRows.count - maxVisibleRows, 0)
        )
        let rowsToShow = Array(visibleRows.enumerated().dropFirst(startIndex).prefix(maxVisibleRows))
        resultsContainer.isHidden = rowsToShow.isEmpty
        hintLabel.isHidden = true

        for (index, row) in rowsToShow {
            let rowView = makeRow(row, isSelected: index == selectedIndex, index: index)
            rowsStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(_ row: PaletteRow, isSelected: Bool, index: Int) -> NSView {
        switch row {
        case .custom(let instruction):
            return makeCustomRow(instruction: instruction, isSelected: isSelected, index: index)
        case .action(let action):
            return makeActionRow(action: action, isSelected: isSelected, index: index)
        }
    }

    private func selectHoveredRow(index: Int) {
        guard selectedIndex != index else { return }
        selectedIndex = index
        renderRows(query: inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func makeActionRow(action: UserSettings.SavedAction, isSelected: Bool, index: Int) -> NSView {
        let row = PaletteRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.09).cgColor
            : NSColor.clear.cgColor
        row.onClick = { [weak self] in
            self?.selectedIndex = index
            self?.runSelected()
        }
        row.onHover = { [weak self] in
            self?.selectHoveredRow(index: index)
        }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        row.addSubview(stack)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
        icon.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        stack.addArrangedSubview(icon)
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let label = NSTextField(labelWithString: action.name)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(label)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if let shortcutKeys = rowShortcutKeys(for: index) {
            stack.addArrangedSubview(makeShortcutKeyGroup(shortcutKeys))
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: rowHeight),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -11),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        return row
    }

    private func makeCustomRow(instruction: String, isSelected: Bool, index: Int) -> NSView {
        let row = PaletteRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.09).cgColor
            : NSColor.clear.cgColor
        row.onClick = { [weak self] in
            self?.selectedIndex = index
            self?.runSelected()
        }
        row.onHover = { [weak self] in
            self?.selectHoveredRow(index: index)
        }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        row.addSubview(stack)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        stack.addArrangedSubview(icon)
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        stack.addArrangedSubview(textStack)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let title = NSTextField(labelWithString: isDefaultImageInstruction(instruction) ? "Ask about attached images" : "Run custom prompt")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: instruction)
        subtitle.font = .systemFont(ofSize: 10, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        textStack.addArrangedSubview(subtitle)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if let shortcutKeys = rowShortcutKeys(for: index) {
            stack.addArrangedSubview(makeShortcutKeyGroup(shortcutKeys))
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: rowHeight),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -11),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        return row
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if matchesConfiguredShortcut(event) {
            close()
            return true
        }
        if paletteMode == .result {
            if flags.contains(.command), Int(event.keyCode) == kVK_ANSI_C {
                copyPreviewResult()
                return true
            }
            if flags.contains(.command), Int(event.keyCode) == kVK_ANSI_V {
                pastePreviewResult()
                return true
            }
            if Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter {
                pastePreviewResult()
                return true
            }
        }
        if paletteMode == .input,
           inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           flags.subtracting(.capsLock) == .command,
           let rowIndex = numericShortcutIndex(for: event),
           visibleRows.indices.contains(rowIndex) {
            selectedIndex = rowIndex
            runRow(visibleRows[rowIndex])
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_DownArrow:
            guard paletteMode == .input else { return false }
            moveSelection(delta: 1)
            return true
        case kVK_UpArrow:
            guard paletteMode == .input else { return false }
            moveSelection(delta: -1)
            return true
        default:
            return false
        }
    }

    private func matchesConfiguredShortcut(_ event: NSEvent) -> Bool {
        let settings = UserSettings.shared
        let shortcutKeyCode = settings.shortcutKeyCode ?? UInt32(kVK_ANSI_E)
        let shortcutModifiers = settings.shortcutModifiers ?? UInt(NSEvent.ModifierFlags([.command, .shift]).rawValue)
        let relevantFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        return UInt32(event.keyCode) == shortcutKeyCode
            && UInt(relevantFlags.rawValue) == shortcutModifiers
    }

    private func numericShortcutIndex(for event: NSEvent) -> Int? {
        switch Int(event.keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        case kVK_ANSI_Keypad1: return 0
        case kVK_ANSI_Keypad2: return 1
        case kVK_ANSI_Keypad3: return 2
        case kVK_ANSI_Keypad4: return 3
        case kVK_ANSI_Keypad5: return 4
        case kVK_ANSI_Keypad6: return 5
        case kVK_ANSI_Keypad7: return 6
        case kVK_ANSI_Keypad8: return 7
        case kVK_ANSI_Keypad9: return 8
        default: return nil
        }
    }

    private func installOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPaletteVisible else { return }
                guard self.shouldDismissOnOutsideClick else { return }
                guard !self.isMouseInsidePalette() else { return }
                self.close()
            }
        }
    }

    private func moveSelection(delta: Int) {
        guard !visibleRows.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), visibleRows.count - 1)
        renderRows(query: inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshRouteWarning()
    }

    private func refreshRouteWarning() {
        paletteWarning = warningForCurrentRow()
        warningLabel?.stringValue = paletteWarning ?? ""
        warningLabel?.isHidden = paletteWarning == nil
        inputHeightConstraint?.constant = currentInputHeight()
        resizeToFit(rowCount: min(visibleRows.count, maxVisibleRows))
    }

    private func validateCanRun(_ row: PaletteRow) -> Bool {
        guard let warning = warning(for: row) else { return true }
        paletteWarning = warning
        renderInputState()
        return false
    }

    private func warningForCurrentRow() -> String? {
        guard let row = currentRowForValidation() else { return nil }
        return warning(for: row)
    }

    private func currentRowForValidation() -> PaletteRow? {
        if visibleRows.indices.contains(selectedIndex) {
            return visibleRows[selectedIndex]
        }

        let instruction = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if instruction.isEmpty, !imageAttachments.isEmpty {
            return .custom(defaultImageInstruction())
        }
        guard !instruction.isEmpty else { return nil }
        return .custom(instruction)
    }

    private func warning(for row: PaletteRow) -> String? {
        guard !imageAttachments.isEmpty else { return nil }
        guard let route = effectiveRoute(for: row) else { return nil }
        guard !route.supportsImages else { return nil }
        return "\(route.displayModel) cannot read images. Pick a model marked Images."
    }

    private func inputPlaceholder() -> String {
        if !imageAttachments.isEmpty {
            return "Ask about attached images..."
        }
        return selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Tell Companion what to write..."
            : "Tell Companion what to do..."
    }

    private func defaultImageInstruction() -> String {
        let noun = imageAttachments.count == 1 ? "image" : "images"
        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Describe the attached \(noun)."
        }
        return "Use the attached \(noun) while working with the selected text."
    }

    private func isDefaultImageInstruction(_ instruction: String) -> Bool {
        !imageAttachments.isEmpty && instruction == defaultImageInstruction()
    }

    private func effectiveRoute(for row: PaletteRow) -> UserSettings.ModelRoute? {
        if let override = routeSelection.routeOverride {
            return override
        }

        switch row {
        case .custom:
            let settings = UserSettings.shared
            if let routeID = settings.customPromptRouteID,
               let route = settings.modelRoute(for: routeID) {
                return route
            }
            return settings.defaultModelRoute(for: settings.customPromptProvider)
        case .action(let action):
            return UserSettings.shared.route(for: action)
        }
    }

    private func makeImageAttachment(from url: URL) throws -> PromptImageAttachment {
        let fileName = url.lastPathComponent
        let mimeType = try mimeType(for: url)
        let shouldStop = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStop {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maxImageBytes {
            throw AttachmentError.tooLarge(fileName)
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxImageBytes else {
            throw AttachmentError.tooLarge(fileName)
        }
        return PromptImageAttachment(fileName: fileName, mimeType: mimeType, data: data)
    }

    private func mimeType(for url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" { return "image/jpeg" }
        if ext == "png" { return "image/png" }
        if ext == "gif" { return "image/gif" }
        if ext == "webp" { return "image/webp" }

        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .image),
           let preferred = type.preferredMIMEType,
           ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(preferred) {
            return preferred
        }

        throw AttachmentError.unsupported(url.lastPathComponent)
    }

    private func positionNearCursor() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let height = window.frame.height
        var origin = NSPoint(x: mouse.x + 18, y: mouse.y - height - 18)

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 12), frame.maxX - paletteWidth - 12)
            origin.y = min(max(origin.y, frame.minY + 12), frame.maxY - height - 12)
        }

        window.setFrame(NSRect(x: origin.x, y: origin.y, width: paletteWidth, height: height), display: true)
    }

    private func position(anchorRect: CGRect?) {
        guard let anchorRect, !anchorRect.isNull, !anchorRect.isEmpty else {
            positionNearCursor()
            return
        }

        guard let window else { return }
        let height = window.frame.height
        let rawRect = NSRect(x: anchorRect.origin.x, y: anchorRect.origin.y, width: anchorRect.width, height: anchorRect.height)
        let rect = normalizedAccessibilityRect(rawRect)
        let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, rect) }) ?? NSScreen.main
        guard let screen else {
            positionNearCursor()
            return
        }

        let frame = screen.visibleFrame
        var origin = NSPoint(
            x: rect.minX,
            y: rect.minY - height - 10
        )

        if origin.y < frame.minY + 12 {
            origin.y = rect.maxY + 10
        }

        origin.x = min(max(origin.x, frame.minX + 12), frame.maxX - paletteWidth - 12)
        origin.y = min(max(origin.y, frame.minY + 12), frame.maxY - height - 12)

        window.setFrame(NSRect(x: origin.x, y: origin.y, width: paletteWidth, height: height), display: true)
    }

    private func normalizedAccessibilityRect(_ rect: NSRect) -> NSRect {
        if NSScreen.screens.contains(where: { NSIntersectsRect($0.frame, rect) }) {
            return rect
        }

        guard let screen = NSScreen.screens.first(where: {
            rect.midX >= $0.frame.minX && rect.midX <= $0.frame.maxX
        }) ?? NSScreen.main else {
            return rect
        }

        return NSRect(
            x: rect.origin.x,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func resizeToFit(rowCount: Int) {
        guard window != nil else { return }
        let safeRowCount = min(max(rowCount, 0), maxVisibleRows)
        let rowsHeight = CGFloat(safeRowCount) * rowHeight
            + CGFloat(max(safeRowCount - 1, 0))
        let trayHeight = safeRowCount > 0
            ? (trayInset * 2) + rowsHeight
            : 0
        let height = inputHeight + (safeRowCount > 0 ? trayTopGap + trayHeight : 0)
        resizeToHeight(height)
    }

    private func resizeToHeight(_ height: CGFloat) {
        guard let window else { return }
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.maxY - height,
            width: paletteWidth,
            height: height
        )
        window.setFrame(newFrame, display: true)
    }

    private func resizeToSize(width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let oldFrame = window.frame
        var newFrame = NSRect(
            x: oldFrame.midX - (width / 2),
            y: oldFrame.maxY - height,
            width: width,
            height: height
        )

        if let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.visibleFrame, oldFrame) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            newFrame.origin.x = min(max(newFrame.origin.x, visibleFrame.minX + 12), visibleFrame.maxX - width - 12)
            newFrame.origin.y = min(max(newFrame.origin.y, visibleFrame.minY + 12), visibleFrame.maxY - height - 12)
        }

        window.setFrame(newFrame, display: true)
    }

    private func runRow(_ row: PaletteRow) {
        guard validateCanRun(row) else { return }
        switch row {
        case .custom(let instruction):
            TextGrabber.shared.runCustomInstruction(
                instruction,
                route: routeSelection,
                images: imageAttachments
            )
        case .action(let action):
            TextGrabber.shared.runSavedAction(
                action,
                route: routeSelection,
                images: imageAttachments
            )
        }
    }

    private func rowShortcutKeys(for index: Int) -> [String]? {
        guard index >= 0, index < 9 else { return nil }
        return ["⌘", "\(index + 1)"]
    }

    private func selectionSummary() -> String? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let words = trimmed
            .split { $0.isWhitespace || $0.isNewline }
            .count
        return words == 1 ? "1 word" : "\(words) words"
    }

    private func selectedTextSnippet() -> String? {
        let trimmed = selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > 120 else { return trimmed }
        return "\(trimmed.prefix(117))..."
    }

    private func focusInputField() {
        guard let window else { return }
        window.makeFirstResponder(inputField)

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.inputField)
            self.scrollInputToEnd()
        }
    }

    private func configureSingleLineField(_ field: NSTextField) {
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
    }

    private func scrollInputToEnd() {
        guard let editor = inputField.currentEditor() else { return }
        let end = inputField.stringValue.utf16.count
        editor.selectedRange = NSRange(location: end, length: 0)
        editor.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    private func isMouseInsidePalette() -> Bool {
        guard let window else { return false }
        let frame = window.frame.insetBy(dx: -8, dy: -8)
        return NSMouseInRect(NSEvent.mouseLocation, frame, false)
    }

    private func clearRootStack() {
        rootStack.arrangedSubviews.forEach { view in
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func closePalette() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        shouldDismissOnDeactivate = true
        shouldDismissOnOutsideClick = true
        previewResultText = ""
        paletteMode = .input
        window?.orderOut(nil)
    }
}

private final class CommandPalettePanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

private final class DraggableVisualEffectView: NSVisualEffectView {
    var onFileDrop: (([URL]) -> Void)? {
        didSet {
            registerForDraggedTypes([.fileURL])
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }
}

private final class PaletteTextField: NSTextField {
    var onCommandNumberShortcut: ((Int) -> Bool)?

    var onFileDrop: (([URL]) -> Void)? {
        didSet {
            registerForDraggedTypes([.fileURL])
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if flags == .command,
           let index = numberShortcutIndex(for: event),
           onCommandNumberShortcut?(index) == true {
            return
        }
        super.keyDown(with: event)
    }

    private func numberShortcutIndex(for event: NSEvent) -> Int? {
        switch Int(event.keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        case kVK_ANSI_Keypad1: return 0
        case kVK_ANSI_Keypad2: return 1
        case kVK_ANSI_Keypad3: return 2
        case kVK_ANSI_Keypad4: return 3
        case kVK_ANSI_Keypad5: return 4
        case kVK_ANSI_Keypad6: return 5
        case kVK_ANSI_Keypad7: return 6
        case kVK_ANSI_Keypad8: return 7
        case kVK_ANSI_Keypad9: return 8
        default: return nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFileDrop?(urls)
        return true
    }
}

private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    return objects ?? []
}

private final class PaletteRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private var rowTrackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let rowTrackingArea {
            removeTrackingArea(rowTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        rowTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
