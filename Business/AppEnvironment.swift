import Foundation

/// Read-only facade for macOS services. It neither owns nor replaces them.
/// iOS composes its own services through AppState.
@MainActor
struct AppEnvironment {

    static let current = AppEnvironment()

    let storage: Storage = Storage.sharedInstance()
    let wikilinkIndex: WikilinkIndex = WikilinkIndex.shared
    let versionManager: NoteVersionManager = NoteVersionManager.shared
    let userData: UserDataService = UserDataService.instance
    let session: EditorSessionState = AppContext.shared.sessionState
    let editingTransitions: EditingTransitionCoordinator = EditingTransitionCoordinator()
}
