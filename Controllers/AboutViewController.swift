import Cocoa

@MainActor
class AboutViewController: NSViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        updateAppearance()

        if let dictionary = Bundle.main.infoDictionary,
            let ver = dictionary["CFBundleShortVersionString"] as? String
        {
            versionLabel.stringValue = "Version \(ver)"
            versionLabel.isSelectable = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateAppearance()
    }

    private func updateAppearance() {
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.panelBackgroundColor.resolvedColor(for: view.effectiveAppearance).cgColor

        for case let label as NSTextField in view.subviews {
            label.textColor =
                (label.stringValue == "Mdown" || label.stringValue == "MiaoYan")
                ? Theme.textColor : Theme.secondaryTextColor
        }
    }

    @IBOutlet var versionLabel: NSTextField!
}
