import AppKit
import XCTest

@testable import Mdown

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

    @MainActor
    func testIdentityMigrationCopiesLegacySuitesAndRebindsMovedLibraryMetadata() throws {
        XCTAssertEqual(AppIdentifier.defaultBundleID, "com.mdown.app")
        XCTAssertEqual(AppIdentifier.cloudContainerID, "iCloud.com.mdown.app")
        XCTAssertEqual(AppIdentifier.legacyBundleID, "com.tw93.miaoyan")

        let id = UUID().uuidString
        let targetName = "mdown.identity.target.\(id)"
        let lowerLegacyName = "mdown.identity.lower.\(id)"
        let upperLegacyName = "mdown.identity.upper.\(id)"
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        let lowerLegacy = try XCTUnwrap(UserDefaults(suiteName: lowerLegacyName))
        let upperLegacy = try XCTUnwrap(UserDefaults(suiteName: upperLegacyName))
        defer {
            target.removePersistentDomain(forName: targetName)
            lowerLegacy.removePersistentDomain(forName: lowerLegacyName)
            upperLegacy.removePersistentDomain(forName: upperLegacyName)
        }

        lowerLegacy.set("/old/Lib", forKey: "storageUrl")
        lowerLegacy.set(17, forKey: "fontSize")
        upperLegacy.set(22, forKey: "fontSize")
        upperLegacy.set("Dark", forKey: "appearanceType")
        target.set(19, forKey: "fontSize")

        UserDefaultsManagement.migrateLegacyPreferences(
            into: target,
            fromSuiteNames: [lowerLegacyName, upperLegacyName],
            markerKey: "HasMigratedMiaoYanToMdown_v1")

        XCTAssertEqual(target.string(forKey: "storageUrl"), "/old/Lib")
        XCTAssertEqual(target.integer(forKey: "fontSize"), 19, "新域已有值不能被旧域覆盖")
        XCTAssertEqual(target.string(forKey: "appearanceType"), "Dark")
        XCTAssertTrue(target.bool(forKey: "HasMigratedMiaoYanToMdown_v1"))

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mdown-rebind-\(id)", isDirectory: true)
        let oldLib = tempRoot.appendingPathComponent("old/MiaoYan", isDirectory: true)
        let newLib = tempRoot.appendingPathComponent("new/Mdown", isDirectory: true)
        let oldVersions = tempRoot.appendingPathComponent("Support/com.tw93.miaoyan/Versions", isDirectory: true)
        let newVersions = tempRoot.appendingPathComponent("Support/com.mdown.app/Versions", isDirectory: true)
        try FileManager.default.createDirectory(at: oldLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newLib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let oldNoteURL = oldLib.appendingPathComponent("Inbox/Keep.md")
        let newNoteURL = newLib.appendingPathComponent("Inbox/Keep.md")
        let oldVersionDir = oldVersions.appendingPathComponent(NoteVersionManager.storageKey(forNoteURL: oldNoteURL), isDirectory: true)
        try FileManager.default.createDirectory(at: oldVersionDir, withIntermediateDirectories: true)
        try "历史正文".write(to: oldVersionDir.appendingPathComponent("2026-10-27T01-02-03Z.md"), atomically: true, encoding: .utf8)

        target.set(["sortBy": "title"], forKey: oldLib.appendingPathComponent("Inbox").path)
        target.set(oldNoteURL.path, forKey: "lastSelectedPath")
        target.set([oldLib.path: 48.0], forKey: "notesTableScrollPosition")

        UserDefaultsManagement.rebindLibraryPaths(
            in: target,
            from: oldLib,
            to: newLib,
            legacyVersionsRoot: oldVersions,
            versionsRoot: newVersions)

        XCTAssertEqual(
            (target.dictionary(forKey: newLib.appendingPathComponent("Inbox").path) as? [String: String])?["sortBy"],
            "title")
        XCTAssertEqual(target.string(forKey: "lastSelectedPath"), newNoteURL.path)
        XCTAssertEqual((target.dictionary(forKey: "notesTableScrollPosition") as? [String: Double])?[newLib.path], 48.0)

        let reboundVersionFile =
            newVersions
            .appendingPathComponent(NoteVersionManager.storageKey(forNoteURL: newNoteURL), isDirectory: true)
            .appendingPathComponent("2026-10-27T01-02-03Z.md")
        XCTAssertEqual(try String(contentsOf: reboundVersionFile, encoding: .utf8), "历史正文")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldVersionDir.path), "旧版本目录必须非破坏保留")
    }

    @MainActor
    func testLegacyXattrCompatibilityForPinsAndTrashMarkers() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdown-xattr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let noteURL = tempDir.appendingPathComponent("Pinned.md")
        try "正文".write(to: noteURL, atomically: true, encoding: .utf8)

        var legacyPinned = true
        try noteURL.setExtendedAttribute(
            data: Data(bytes: &legacyPinned, count: 1),
            forName: AppIdentifier.legacyPinKey)

        let project = Project(url: tempDir, label: "Temp", isTrash: false, isRoot: true)
        let note = Note(url: noteURL, with: project)
        note.loadMetadataFromDisk()
        XCTAssertTrue(note.isPinned, "仅含旧 com.tw93.miaoyan.pin 的笔记在升级后必须保持置顶")

        note.removePin(cloudSave: false)
        note.loadMetadataFromDisk()
        XCTAssertFalse(note.isPinned, "取消置顶必须同步更新新旧 xattr，重新加载不能回退成已置顶")

        let trashFileURL = tempDir.appendingPathComponent("Removed.md")
        try "垃圾".write(to: trashFileURL, atomically: true, encoding: .utf8)
        try trashFileURL.setExtendedAttribute(
            data: Data([1]),
            forName: AppIdentifier.legacyRemovedFromTrashKey)
        let trashProject = Project(url: tempDir, label: "Trash", isTrash: true, isRoot: false)
        XCTAssertTrue(
            Storage.shouldHideRemovedTrashItem(at: trashFileURL, in: trashProject),
            "旧版标记为已从废纸篓移除的文件在新身份下仍应隐藏")
    }
}
