import Cocoa

@MainActor
final class EditorPrefsViewController: BasePrefsViewController {
    private var settings = EditorSettings()
    private var settingsStackView: NSStackView!

    override func setupUI() {
        setupEditorSettingsSection(in: installPreferencesStack())
    }

    private func setupEditorSettingsSection(in stackView: NSStackView) {
        settingsStackView = stackView

        let lineBreakRow = createSettingRow(
            label: I18n.str("Line Break:"),
            options: [localizedLineBreak("MiaoYan"), localizedLineBreak("Github")],
            action: #selector(lineBreakChanged(_:))
        )
        settingsStackView.addArrangedSubview(lineBreakRow)

        let uploadRow = createSettingRow(
            label: I18n.str("Upload Service:"),
            options: [I18n.str("None"), "uPic", "PicGo", "Picsee", "PicList"],
            action: #selector(uploadServiceChanged(_:))
        )
        settingsStackView.addArrangedSubview(uploadRow)

        let locationRow = createSettingRow(
            label: I18n.str("Preview Location:"),
            options: [localizedPreviewLocation("Begin"), localizedPreviewLocation("Editing")],
            action: #selector(previewLocationChanged(_:))
        )
        settingsStackView.addArrangedSubview(locationRow)

        let widthRow = createSettingRow(
            label: I18n.str("Preview Width:"),
            options: [
                localizedPreviewWidth("600px"), localizedPreviewWidth("800px"), localizedPreviewWidth("1000px"), localizedPreviewWidth("1200px"), localizedPreviewWidth("1400px"), localizedPreviewWidth(UserDefaultsManagement.FullWidthValue),
            ],
            action: #selector(previewWidthChanged(_:))
        )
        settingsStackView.addArrangedSubview(widthRow)
    }

    private func createSectionView(in parentView: NSView, topAnchor: NSLayoutAnchor<NSLayoutYAxisAnchor>, topConstant: CGFloat, title: String? = nil) -> (container: NSView, titleLabel: NSTextField?) {
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        var titleLabel: NSTextField?
        if let title = title {
            let label = NSTextField(labelWithString: title)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.boldSystemFont(ofSize: 13)
            label.textColor = Theme.textColor
            containerView.addSubview(label)
            titleLabel = label
        }

        parentView.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            containerView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
        ])

        if let titleLabel {
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
                titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            ])
        }

        return (containerView, titleLabel)
    }

    private func createSettingRow(label: String, options: [String], action: Selector) -> NSView {
        let popUp = NSPopUpButton()
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.target = self
        popUp.action = action

        for option in options {
            popUp.addItem(withTitle: option)
        }

        return makePreferencesRow(labelText: label, control: popUp)
    }

    override func setupValues() {
        selectLineBreakOption(settings.editorLineBreak)
        selectUploadServiceOption(UserDefaultsManagement.defaultPicUpload)
        selectPreviewLocationOption(settings.previewLocation)
        selectPreviewWidthOption(settings.previewWidth)
    }

    private func selectLineBreakOption(_ value: String) {
        guard !settingsStackView.arrangedSubviews.isEmpty,
            let popUp = settingsStackView.arrangedSubviews[0].subviews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton
        else { return }
        popUp.selectItem(withTitle: localizedLineBreak(value))
    }

    private func selectPreviewLocationOption(_ value: String) {
        guard settingsStackView.arrangedSubviews.count > 2,
            let popUp = settingsStackView.arrangedSubviews[2].subviews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton
        else { return }
        popUp.selectItem(withTitle: localizedPreviewLocation(value))
    }

    private func selectPreviewWidthOption(_ value: String) {
        guard settingsStackView.arrangedSubviews.count > 3,
            let popUp = settingsStackView.arrangedSubviews[3].subviews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton
        else { return }
        popUp.selectItem(withTitle: localizedPreviewWidth(value))
    }

    private func selectUploadServiceOption(_ value: String) {
        guard settingsStackView.arrangedSubviews.count > 1,
            let popUp = settingsStackView.arrangedSubviews[1].subviews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton
        else { return }
        if value == "None" {
            popUp.selectItem(withTitle: I18n.str("None"))
        } else {
            popUp.selectItem(withTitle: value)
        }
    }

    // MARK: - Actions

    @objc private func lineBreakChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        settings.editorLineBreak = rawLineBreak(from: item.title)
        settings.applyChanges()
    }

    @objc private func previewLocationChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        settings.previewLocation = rawPreviewLocation(from: item.title)
        settings.applyChanges()
    }

    @objc private func previewWidthChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        settings.previewWidth = rawPreviewWidth(from: item.title)
        settings.applyChanges()
    }

    @objc private func uploadServiceChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        let title = item.title
        UserDefaultsManagement.defaultPicUpload = (title == I18n.str("None")) ? "None" : title
        if title != "None", let vc = ViewController.shared() {
            vc.toastImageSet(name: title)
        }
    }

    // MARK: - Localization Helpers for raw/display mapping
    private func localizedLineBreak(_ raw: String) -> String {
        switch raw {
        case "MiaoYan": return I18n.str("Mdown")
        case "Github": return I18n.str("Github")
        default: return raw
        }
    }

    private func rawLineBreak(from display: String) -> String {
        if display == I18n.str("Mdown") { return "MiaoYan" }
        if display == I18n.str("Github") { return "Github" }
        return display
    }

    private func localizedPreviewLocation(_ raw: String) -> String {
        switch raw {
        case "Begin": return I18n.str("Begin")
        case "Editing": return I18n.str("Editing")
        default: return raw
        }
    }

    private func rawPreviewLocation(from display: String) -> String {
        if display == I18n.str("Begin") { return "Begin" }
        if display == I18n.str("Editing") { return "Editing" }
        return display
    }

    private func localizedPreviewWidth(_ raw: String) -> String {
        if raw == UserDefaultsManagement.FullWidthValue { return I18n.str("Full Width") }
        return raw
    }

    private func rawPreviewWidth(from display: String) -> String {
        if display == I18n.str("Full Width") { return UserDefaultsManagement.FullWidthValue }
        return display
    }

}
