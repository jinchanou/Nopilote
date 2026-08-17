import Foundation
import XCTest
@testable import Nopilote

final class AppModelEditCycleTests: XCTestCase {
    @MainActor
    func testTypedComposerTextAlwaysUsesAskRegardlessOfSelectedMode() async throws {
        let ai = RecordingAIService()
        let model = try makeModel(ai: ai)
        model.selectedAction = .outline
        model.prompt = "你觉得这份笔记怎么样？"
        await model.loadCurrentNote()

        await model.send()

        let request = await ai.lastRequest()
        XCTAssertEqual(request?.action, .ask)
        XCTAssertEqual(request?.prompt, "你觉得这份笔记怎么样？")
        XCTAssertNil(model.proposal)
    }

    @MainActor
    func testEmptyComposerUsesSelectedModeDefaultCommand() async throws {
        let ai = RecordingAIService()
        let model = try makeModel(ai: ai)
        model.selectedAction = .outline
        model.prompt = "   "
        await model.loadCurrentNote()

        await model.send()

        let request = await ai.lastRequest()
        XCTAssertEqual(request?.action, .outline)
        XCTAssertEqual(request?.prompt, "Turn this note into a clear logical outline.")
        XCTAssertNotNil(model.proposal)
    }

    @MainActor
    func testModelMenuAvailabilityIsIndependentPerProvider() throws {
        let suite = "NopiloteTests.providers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai-key", forKey: "nopilote.apiKey.v1.openAI")
        let model = AppModel(notes: StatefulNotesService(), defaults: defaults, allowsOfflineProvider: true)

        XCTAssertTrue(model.hasAPIKey(for: .openAI))
        XCTAssertFalse(model.hasAPIKey(for: .deepSeek))
        model.selectConfiguredProvider(.deepSeek)
        XCTAssertEqual(model.provider, .openAI)

        defaults.set("deepseek-key", forKey: "nopilote.apiKey.v1.deepSeek")
        model.selectConfiguredProvider(.deepSeek)
        XCTAssertEqual(model.provider, .deepSeek)
    }

    @MainActor
    func testReplaceUndoThenReplaceAgain() async throws {
        let notes = StatefulNotesService()
        let suite = "NopiloteTests.edit-cycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "cloudConsentGranted")
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(
            notes: notes,
            ai: ProposalAIService(),
            defaults: defaults,
            allowsOfflineProvider: true
        )
        model.selectedAction = .rewrite
        await model.loadCurrentNote()

        await model.send()
        XCTAssertNotNil(model.proposal)
        await model.applyProposal(createCopy: false)
        XCTAssertTrue(model.undoAvailable)

        await model.undoLastEdit()
        XCTAssertFalse(model.undoAvailable)

        await model.send()
        XCTAssertNotNil(model.proposal)
        await model.applyProposal(createCopy: false)

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.proposal)
        let replacementCount = await notes.replaceCount()
        XCTAssertEqual(replacementCount, 3)
    }

    @MainActor
    func testEndSessionDropsNoteAndConversation() async throws {
        let notes = StatefulNotesService()
        let model = try makeModel(ai: RecordingAIService(), notes: notes)
        await model.loadCurrentNote()
        model.prompt = "hello"
        await model.send()
        XCTAssertNotNil(model.note)
        XCTAssertFalse(model.messages.isEmpty)

        model.endSession()

        XCTAssertNil(model.note)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.lastNoteSync)
        let replacementCount = await notes.replaceCount()
        XCTAssertEqual(replacementCount, 0)
    }

    @MainActor
    private func makeModel(ai: any AIServing, notes: any NotesServing = StatefulNotesService()) throws -> AppModel {
        let suite = "NopiloteTests.composer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "cloudConsentGranted")
        return AppModel(
            notes: notes,
            ai: ai,
            defaults: defaults,
            allowsOfflineProvider: true
        )
    }
}

private actor RecordingAIService: AIServing {
    struct Request: Sendable {
        let prompt: String
        let action: NopiloteAction
    }

    private var request: Request?

    func respond(
        configuration: AIProviderConfiguration,
        note: NoteSnapshot,
        messages: [ChatMessage],
        prompt: String,
        action: NopiloteAction
    ) async throws -> AIResponse {
        request = Request(prompt: prompt, action: action)
        let proposal = action.requiresProposal ? NoteProposalContent(
            title: "Outline",
            blocks: [DocumentBlock(kind: .paragraph, text: "Outline", items: nil, level: nil)]
        ) : nil
        return AIResponse(answer: "Answer", proposal: proposal)
    }

    func lastRequest() -> Request? { request }
}

private actor StatefulNotesService: NotesServing {
    private var html = "<h1>Original</h1><p>Body</p>"
    private var tokenNumber = 1
    private var replacements = 0

    func selectedNoteID() async throws -> String { "note-1" }

    func selectedNote() async throws -> NoteSnapshot {
        NoteSnapshot(
            id: "note-1",
            title: "Original",
            account: "iCloud",
            folder: "Tests",
            folderID: "folder-1",
            html: html,
            plainText: html,
            modificationDate: nil,
            modificationToken: "token-\(tokenNumber)",
            isLocked: false,
            isShared: false
        )
    }

    func refreshMetadata(id: String) async throws -> (isLocked: Bool, modificationToken: String) {
        (false, "token-\(tokenNumber)")
    }

    func replaceNote(id: String, html: String, expectedToken: String) async throws {
        guard expectedToken == "token-\(tokenNumber)" else {
            throw NoteAccessError.changedSincePreview
        }
        self.html = html
        tokenNumber += 1
        replacements += 1
    }

    func createNote(folderID: String, html: String) async throws -> String { "copy-1" }
    func showNote(id: String) async throws {}
    func replaceCount() -> Int { replacements }
}

private struct ProposalAIService: AIServing {
    func respond(
        configuration: AIProviderConfiguration,
        note: NoteSnapshot,
        messages: [ChatMessage],
        prompt: String,
        action: NopiloteAction
    ) async throws -> AIResponse {
        AIResponse(
            answer: "Rewritten.",
            proposal: NoteProposalContent(
                title: "Rewritten",
                blocks: [
                    DocumentBlock(
                        kind: .paragraph,
                        text: "Updated body",
                        items: nil,
                        level: nil
                    )
                ]
            )
        )
    }
}
