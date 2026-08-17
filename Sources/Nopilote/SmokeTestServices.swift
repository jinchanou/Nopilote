import Foundation

struct SmokeTestNotesService: NotesServing {
    private static let snapshot = NoteSnapshot(
        id: "smoke-note",
        title: "Product ideas",
        account: "iCloud",
        folder: "Demo",
        folderID: "smoke-folder",
        html: "<h1>Product ideas</h1><p>Build a focused notes assistant.</p>",
        plainText: "Product ideas\nBuild a focused notes assistant.",
        modificationDate: Date(timeIntervalSince1970: 0),
        modificationToken: "1970-01-01T00:00:00Z",
        isLocked: false,
        isShared: false
    )

    func selectedNoteID() async throws -> String { Self.snapshot.id }
    func selectedNote() async throws -> NoteSnapshot { Self.snapshot }
    func refreshMetadata(id: String) async throws -> (isLocked: Bool, modificationToken: String) {
        (false, Self.snapshot.modificationToken)
    }
    func replaceNote(id: String, html: String, expectedToken: String) async throws {}
    func createNote(folderID: String, html: String) async throws -> String { "smoke-copy" }
    func showNote(id: String) async throws {}
}

struct SmokeTestAIService: AIServing {
    func respond(
        configuration: AIProviderConfiguration,
        note: NoteSnapshot,
        messages: [ChatMessage],
        prompt: String,
        action: NopiloteAction
    ) async throws -> AIResponse {
        AIResponse(
            answer: "This is an offline smoke-test response.",
            proposal: action.requiresProposal ? NoteProposalContent(
                title: "Product ideas - organized",
                blocks: [
                    DocumentBlock(kind: .heading, text: "Goal", items: nil, level: 2, rows: nil, checked: nil),
                    DocumentBlock(kind: .paragraph, text: "Build a focused notes assistant.", items: nil, level: nil, rows: nil, checked: nil)
                ]
            ) : nil
        )
    }
}

struct SmokeTestAccessDeniedService: NotesServing {
    private let message = "Apple Notes denied the automation request. Open System Settings, enable Notes for Nopilote, then return here and choose Try again."

    func selectedNoteID() async throws -> String { throw NoteAccessError.automationDenied(message) }
    func selectedNote() async throws -> NoteSnapshot { throw NoteAccessError.automationDenied(message) }
    func refreshMetadata(id: String) async throws -> (isLocked: Bool, modificationToken: String) { throw NoteAccessError.automationDenied(message) }
    func replaceNote(id: String, html: String, expectedToken: String) async throws { throw NoteAccessError.automationDenied(message) }
    func createNote(folderID: String, html: String) async throws -> String { throw NoteAccessError.automationDenied(message) }
    func showNote(id: String) async throws { throw NoteAccessError.automationDenied(message) }
}
