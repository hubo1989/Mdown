import AppKit
import Foundation
import WebKit

extension MPreviewView {

    @objc public func exportCurrentDiagram(_ sender: Any?) {
        guard let note = displayedNote,
            let preflight = activeDiagramPreflight,
            preflight.isReady
        else {
            return
        }

        let currentBlockId = preflight.identity.blockId
        let currentRevision = preflight.identity.renderRevision

        evaluateJavaScript("window.__miaoyanGetActiveDiagramSnapshot()") { [weak self] rawResult, error in
            guard let self = self else { return }

            if let error = error {
                AppDelegate.trackError(error, context: "DiagramExport.getSnapshot")
                AppContext.shared.viewController?.toast(message: NSLocalizedString("Failed to export diagram", comment: ""), style: .failure)
                return
            }

            guard let dict = rawResult as? [String: Any],
                let blockId = dict["blockId"] as? String,
                blockId == currentBlockId,
                let kindRaw = dict["kind"] as? String,
                let kind = RenderedBlockKind(rawValue: kindRaw),
                let naturalWidth = (dict["naturalWidth"] as? NSNumber)?.doubleValue,
                let naturalHeight = (dict["naturalHeight"] as? NSNumber)?.doubleValue,
                let isDark = dict["isDark"] as? Bool
            else {
                return
            }

            let svgContent = dict["svgContent"] as? String
            let htmlContent = dict["htmlContent"] as? String
            guard svgContent != nil || htmlContent != nil else {
                return
            }

            let revision = (dict["revision"] as? NSNumber)?.intValue ?? currentRevision
            guard revision == currentRevision else {
                AppContext.shared.viewController?.toast(message: NSLocalizedString("Failed to export diagram", comment: ""), style: .failure)
                return
            }

            let identity = RenderedBlockIdentity(
                noteId: note.name,
                previewGeneration: 1,
                blockId: blockId,
                renderRevision: revision
            )

            let snapshot = RenderedBlockSnapshot(
                identity: identity,
                kind: kind,
                svgContent: svgContent,
                htmlContent: htmlContent,
                naturalWidth: CGFloat(naturalWidth),
                naturalHeight: CGFloat(naturalHeight),
                padding: 16.0,
                isDark: isDark
            )

            self.presentDiagramSavePanel(snapshot: snapshot, note: note, supportsSvg: preflight.supportsSvg && svgContent != nil)
        }
    }

    private func presentDiagramSavePanel(snapshot: RenderedBlockSnapshot, note: Note, supportsSvg: Bool) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false

        let sanitizedTitle = note.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let noteName = sanitizedTitle.isEmpty ? "diagram" : sanitizedTitle
        panel.nameFieldStringValue = "\(noteName)-\(snapshot.identity.blockId).png"

        // Accessory View Controls
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))

        // 1. Format PopUp
        let formatLabel = NSTextField(labelWithString: NSLocalizedString("Format", comment: "") + ":")
        formatLabel.frame = NSRect(x: 20, y: 68, width: 80, height: 20)
        formatLabel.alignment = .right

        let formatPopUp = NSPopUpButton(frame: NSRect(x: 105, y: 65, width: 140, height: 25), pullsDown: false)
        if supportsSvg {
            formatPopUp.addItems(withTitles: ["PNG", "SVG"])
            formatPopUp.selectItem(withTitle: "PNG")
        } else {
            formatPopUp.addItems(withTitles: ["PNG"])
            formatPopUp.selectItem(withTitle: "PNG")
            formatPopUp.isEnabled = false
        }

        // 2. Scale PopUp
        let scaleLabel = NSTextField(labelWithString: NSLocalizedString("Scale", comment: "") + ":")
        scaleLabel.frame = NSRect(x: 20, y: 38, width: 80, height: 20)
        scaleLabel.alignment = .right

        let scalePopUp = NSPopUpButton(frame: NSRect(x: 105, y: 35, width: 140, height: 25), pullsDown: false)
        scalePopUp.addItems(withTitles: ["1×", "2×", "3×"])
        scalePopUp.selectItem(withTitle: "2×")

        // 3. Background PopUp
        let bgLabel = NSTextField(labelWithString: NSLocalizedString("Background", comment: "") + ":")
        bgLabel.frame = NSRect(x: 20, y: 8, width: 80, height: 20)
        bgLabel.alignment = .right

        let bgPopUp = NSPopUpButton(frame: NSRect(x: 105, y: 5, width: 180, height: 25), pullsDown: false)
        let bgOptions = [
            NSLocalizedString("Follow Theme", comment: ""),
            NSLocalizedString("Transparent", comment: ""),
            NSLocalizedString("Light", comment: ""),
            NSLocalizedString("Dark", comment: ""),
        ]
        bgPopUp.addItems(withTitles: bgOptions)
        bgPopUp.selectItem(at: 0)

        formatPopUp.target = self
        scalePopUp.target = self

        accessoryView.addSubview(formatLabel)
        accessoryView.addSubview(formatPopUp)
        accessoryView.addSubview(scaleLabel)
        accessoryView.addSubview(scalePopUp)
        accessoryView.addSubview(bgLabel)
        accessoryView.addSubview(bgPopUp)

        panel.accessoryView = accessoryView

        let window = self.window ?? NSApp.keyWindow

        let handleSave = { (targetURL: URL) in
            let selectedFormatIndex = formatPopUp.indexOfSelectedItem
            let isSvg = selectedFormatIndex == 1 || targetURL.pathExtension.lowercased() == "svg"

            let selectedScale: ExportScale
            switch scalePopUp.indexOfSelectedItem {
            case 0: selectedScale = .scale1x
            case 2: selectedScale = .scale3x
            default: selectedScale = .scale2x
            }

            let selectedBackground: ExportBackground
            switch bgPopUp.indexOfSelectedItem {
            case 1: selectedBackground = .transparent
            case 2: selectedBackground = .light
            case 3: selectedBackground = .dark
            default: selectedBackground = .theme
            }

            Task { @MainActor in
                do {
                    if isSvg {
                        _ = try RenderedBlockExportController.shared.exportSvg(snapshot: snapshot, to: targetURL)
                    } else {
                        _ = try await RenderedBlockExportController.shared.exportPng(
                            snapshot: snapshot,
                            scale: selectedScale,
                            background: selectedBackground,
                            to: targetURL
                        )
                    }
                    AppContext.shared.viewController?.toast(
                        message: NSLocalizedString("Diagram exported successfully", comment: ""),
                        style: .success
                    )
                } catch {
                    AppDelegate.trackError(error, context: "DiagramExport.save")
                    AppContext.shared.viewController?.toast(
                        message: NSLocalizedString("Failed to export diagram", comment: ""),
                        style: .failure
                    )
                }
            }
        }

        if let window = window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let targetURL = panel.url else { return }
                handleSave(targetURL)
            }
        } else {
            let response = panel.runModal()
            guard response == .OK, let targetURL = panel.url else { return }
            handleSave(targetURL)
        }
    }
}
