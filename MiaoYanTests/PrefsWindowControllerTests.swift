import AppKit
import XCTest

@testable import MiaoYan

final class PrefsWindowControllerTests: XCTestCase {
    @MainActor
    func testFontMigrationPreservesCustomFaces() throws {
        let defaults = UserDefaults.standard
        let keys = ["fontName", "windowFontName", "previewFontName", "codeFont", "hasMigratedSystemFonts_v1", "hasMigratedCodeFontDefault_v1", "hasMigratedFontDefaults_v2"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "hasMigratedSystemFonts_v1")
        defaults.set(true, forKey: "hasMigratedCodeFontDefault_v1")
        defaults.set(true, forKey: "hasMigratedFontDefaults_v2")
        defaults.set("TsangerJinKai02-W04", forKey: "fontName")
        defaults.set("TsangerJinKai02-W04", forKey: "windowFontName")
        defaults.set("Helvetica", forKey: "previewFontName")
        defaults.set("Menlo", forKey: "codeFont")

        UserDefaultsManagement.migrateFontDefaultsIfNeeded()

        XCTAssertEqual(UserDefaultsManagement.fontName, FontConfiguration.defaultEditorFont)
        XCTAssertEqual(UserDefaultsManagement.windowFontName, FontConfiguration.defaultInterfaceFont)
        XCTAssertEqual(UserDefaultsManagement.previewFontName, "Helvetica")
        XCTAssertEqual(UserDefaultsManagement.codeFontName, "Menlo")
        XCTAssertNotNil(NSFont(name: FontConfiguration.defaultEditorFont, size: 16))
    }

    func testWindowAppearanceDoesNotOverwriteTheSavedPreviewMode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Controllers/ViewController.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "override func viewDidAppear()"))
        let end = try XCTUnwrap(source.range(of: "private func installLiveResizeObserverIfNeeded", range: start.upperBound..<source.endIndex))
        let appearance = String(source[start.upperBound..<end.lowerBound])
        XCTAssertNil(appearance.range(of: #"sessionPreviewMode\s*=\s*false"#, options: .regularExpression))
        XCTAssertTrue(appearance.contains("enablePreview()"))
    }

    @MainActor
    func testPreferencesWindowTracksAlwaysOnTopSetting() {
        let originalValue = UserDefaultsManagement.alwaysOnTop
        UserDefaultsManagement.alwaysOnTop = true

        let controller = PrefsWindowController()
        controller.show()

        defer {
            controller.window?.orderOut(nil)
            UserDefaultsManagement.alwaysOnTop = originalValue
            NotificationCenter.default.post(name: .alwaysOnTopChanged, object: nil)
        }

        XCTAssertEqual(controller.window?.level, .floating)

        UserDefaultsManagement.alwaysOnTop = false
        NotificationCenter.default.post(name: .alwaysOnTopChanged, object: nil)

        XCTAssertEqual(controller.window?.level, .normal)
    }

    @MainActor
    func testToolbarButtonVisualStateOnActiveAndInactive() {
        let vc = ViewController()
        let button = NSButton()
        let activeTint = NSColor.systemGreen
        let inactiveTint = NSColor.secondaryLabelColor

        // 1. Inactive state
        vc.applyToolbarButtonState(button, isActive: false, activeTint: activeTint, inactiveTint: inactiveTint)
        XCTAssertEqual(button.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(button.contentTintColor, inactiveTint)

        // 2. Active state
        vc.applyToolbarButtonState(button, isActive: true, activeTint: activeTint, inactiveTint: inactiveTint)
        let expectedBg = Theme.toolbarButtonActiveBackgroundColor.resolvedColor(for: button.effectiveAppearance).cgColor
        XCTAssertEqual(button.layer?.backgroundColor, expectedBg)
        XCTAssertEqual(button.layer?.cornerRadius, 4)
        XCTAssertTrue(button.layer?.masksToBounds == true)
        XCTAssertEqual(button.contentTintColor, activeTint)
    }
}
