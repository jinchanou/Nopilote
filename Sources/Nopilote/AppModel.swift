import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var note: NoteSnapshot?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var proposal: EditProposal?
    @Published var prompt = ""
    @Published var selectedAction: NopiloteAction = .ask
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var cloudConsentPending = false
    @Published var provider: AIProviderKind
    @Published var modelName: String
    @Published var isPinned = false
    @Published private(set) var lastNoteSync: Date?
    @Published private(set) var undoAvailable = false

    private let notes: any NotesServing
    private let ai: any AIServing
    private let defaults: UserDefaults
    private let allowsOfflineProvider: Bool
    private var idleTask: Task<Void, Never>?
    private var loadedAPIKeyAccounts = Set<String>()
    private var apiKeyCache: [String: String] = [:]
    private var apiKeyReadError: Error?
    private var undoEdit: UndoEdit?

    init(
        notes: any NotesServing = AppleNotesService(),
        ai: any AIServing = AIService(),
        defaults: UserDefaults = .standard,
        allowsOfflineProvider: Bool = false
    ) {
        self.notes = notes
        self.ai = ai
        self.defaults = defaults
        self.allowsOfflineProvider = allowsOfflineProvider
        let storedKind = defaults.string(forKey: "provider").flatMap(AIProviderKind.init(rawValue:)) ?? .openAI
        provider = storedKind
        modelName = defaults.string(forKey: "model.\(storedKind.rawValue)") ?? storedKind.defaultModel
        cloudConsentPending = !defaults.bool(forKey: "cloudConsentGranted")
        observeScreenLock()
        resetIdleTimer()
    }

    deinit {
        idleTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var apiKey: String {
        let account = provider.keychainAccount
        if loadedAPIKeyAccounts.contains(account) { return apiKeyCache[account] ?? "" }
        let value = defaults.string(forKey: apiKeyStorageKey) ?? ""
        loadedAPIKeyAccounts.insert(account)
        apiKeyCache[account] = value
        apiKeyReadError = nil
        return value
    }
    var hasAPIKey: Bool { !apiKey.isEmpty }
    var hasEnteredPrompt: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasStoredAPIKey: Bool {
        !apiKey.isEmpty
    }
    func hasAPIKey(for kind: AIProviderKind) -> Bool {
        let storageKey = "nopilote.apiKey.v1.\(kind.rawValue)"
        return !(defaults.string(forKey: storageKey) ?? "").isEmpty
    }
    var activeModelLabel: String {
        "\(provider.name) · \(modelName)"
    }
    var apiKeyErrorMessage: String? { apiKeyReadError?.localizedDescription }

    private var apiKeyConfiguredKey: String {
        "apiKeyConfigured.\(provider.rawValue)"
    }

    private var apiKeyStorageKey: String {
        "nopilote.apiKey.v1.\(provider.rawValue)"
    }

    func selectProvider(_ kind: AIProviderKind) {
        provider = kind
        apiKeyReadError = nil
        modelName = defaults.string(forKey: "model.\(kind.rawValue)") ?? kind.defaultModel
        defaults.set(kind.rawValue, forKey: "provider")
    }

    func selectConfiguredProvider(_ kind: AIProviderKind) {
        guard hasAPIKey(for: kind) else { return }
        selectProvider(kind)
    }

    func saveModelName() {
        let cleaned = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        modelName = cleaned
        defaults.set(cleaned, forKey: "model.\(provider.rawValue)")
        defaults.set(provider.rawValue, forKey: "provider")
    }

    func saveSettings(apiKey: String) throws {
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        loadedAPIKeyAccounts.insert(provider.keychainAccount)
        apiKeyCache[provider.keychainAccount] = cleaned
        apiKeyReadError = nil
        defaults.set(cleaned, forKey: apiKeyStorageKey)
        defaults.set(true, forKey: apiKeyConfiguredKey)
        defaults.set(modelName, forKey: "model.\(provider.rawValue)")
        defaults.set(provider.rawValue, forKey: "provider")
    }

    func removeAPIKey() {
        loadedAPIKeyAccounts.insert(provider.keychainAccount)
        apiKeyCache.removeValue(forKey: provider.keychainAccount)
        apiKeyReadError = nil
        defaults.removeObject(forKey: apiKeyStorageKey)
        defaults.set(false, forKey: apiKeyConfiguredKey)
    }

    func grantCloudConsent() {
        defaults.set(true, forKey: "cloudConsentGranted")
        cloudConsentPending = false
    }

    func loadCurrentNote() async {
        resetIdleTimer()
        isWorking = true
        errorMessage = nil
        undoEdit = nil
        undoAvailable = false
        do {
            note = try await notes.selectedNote()
            lastNoteSync = Date()
            proposal = nil
        } catch {
            note = nil
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func monitorCurrentNoteSelection() async {
        await loadCurrentNote()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !isWorking, proposal == nil else { continue }
            do {
                let selectedID = try await notes.selectedNoteID()
                if selectedID != note?.id {
                    await loadCurrentNote()
                }
            } catch NoteAccessError.locked {
                note = nil
                lastNoteSync = Date()
                errorMessage = NoteAccessError.locked.localizedDescription
            } catch NoteAccessError.noSelection {
                note = nil
                lastNoteSync = Date()
                errorMessage = NoteAccessError.noSelection.localizedDescription
            } catch {
                // Keep the last confirmed note visible through transient Notes automation failures.
            }
        }
    }

    func showCurrentNoteInNotes() async {
        guard let note else { return }
        do {
            try await notes.showNote(id: note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        if note == nil {
            await loadCurrentNote()
        }
        guard note != nil else { return }
        guard !cloudConsentPending else { return }

        // Undo and Apple Notes can update the selected entry asynchronously.
        // Always build a proposal from a fresh snapshot so it never carries a
        // stale body or modification token into the next replacement.
        do {
            note = try await notes.selectedNote()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let note else { return }

        if !allowsOfflineProvider {
            let configuredKey = apiKey
            if let apiKeyReadError {
                errorMessage = AppError.apiKeyUnavailable(apiKeyReadError.localizedDescription).localizedDescription
                return
            }
            guard !configuredKey.isEmpty else {
                errorMessage = AppError.missingAPIKey.localizedDescription
                return
            }
        }

        let enteredPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // The composer is always an Ask entry point. The selected action is
        // used only when the composer is empty and its default command is sent.
        let action: NopiloteAction = enteredPrompt.isEmpty ? selectedAction : .ask
        let requestText = enteredPrompt.isEmpty ? defaultPrompt(for: action) : enteredPrompt
        guard !requestText.isEmpty else { return }
        resetIdleTimer()
        isWorking = true
        errorMessage = nil
        let history = messages
        messages.append(ChatMessage(role: .user, content: requestText))
        prompt = ""

        do {
            let response = try await ai.respond(
                configuration: AIProviderConfiguration(kind: provider, model: modelName, apiKey: allowsOfflineProvider ? "offline" : apiKey),
                note: note,
                messages: history,
                prompt: requestText,
                action: action
            )
            let imageNotice = AIService.imageNotice(
                note: note,
                configuration: AIProviderConfiguration(kind: provider, model: modelName, apiKey: "")
            )
            let visionNotice = AIService.visionImageNotice(
                note: note,
                configuration: AIProviderConfiguration(kind: provider, model: modelName, apiKey: "")
            )
            messages.append(ChatMessage(role: .assistant, content: imageNotice + visionNotice + response.answer))
            // Ask may optionally propose an edit when the user's request calls
            // for changing the note. Summarize never opens this review sheet.
            if action.allowsProposal, let content = response.proposal {
                let html = NoteHTML.render(title: content.title, blocks: content.blocks)
                proposal = EditProposal(
                    noteID: note.id,
                    expectedModificationToken: note.modificationToken,
                    originalTitle: note.title,
                    originalPlainText: note.plainText,
                    proposedTitle: content.title,
                    proposedPlainText: NoteHTML.plainText(title: content.title, blocks: content.blocks),
                    proposedHTML: html,
                    requiresNewNote: note.hasComplexFormatting
                )
            }
        } catch is CancellationError {
            messages.removeLast()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func applyProposal(createCopy: Bool) async {
        guard let proposal, let note else { return }
        guard !isWorking else { return }
        resetIdleTimer()
        isWorking = true
        errorMessage = nil
        do {
            let metadata = try await notes.refreshMetadata(id: proposal.noteID)
            if metadata.isLocked { throw NoteAccessError.locked }
            let expected = proposal.expectedModificationToken
            guard metadata.modificationToken == expected else { throw NoteAccessError.changedSincePreview }
            if createCopy || proposal.requiresNewNote {
                let id = try await notes.createNote(folderID: note.folderID, html: proposal.proposedHTML)
                try await notes.showNote(id: id)
            } else {
                let originalHTML = note.html
                try await notes.replaceNote(id: proposal.noteID, html: proposal.proposedHTML, expectedToken: expected)
                try await notes.showNote(id: proposal.noteID)
                let updatedNote = try await waitForNote(id: proposal.noteID, afterToken: expected)
                undoEdit = UndoEdit(
                    noteID: proposal.noteID,
                    originalHTML: originalHTML,
                    expectedModificationToken: updatedNote.modificationToken
                )
                undoAvailable = true
            }
            self.note = try await notes.selectedNote()
            self.proposal = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func discardProposal() { proposal = nil }

    func undoLastEdit() async {
        guard let undoEdit, let note, note.id == undoEdit.noteID else { return }
        guard !isWorking else { return }
        resetIdleTimer()
        isWorking = true
        errorMessage = nil
        do {
            let metadata = try await notes.refreshMetadata(id: undoEdit.noteID)
            if metadata.isLocked { throw NoteAccessError.locked }
            guard metadata.modificationToken == undoEdit.expectedModificationToken else {
                throw NoteAccessError.changedSincePreview
            }
            try await notes.replaceNote(
                id: undoEdit.noteID,
                html: undoEdit.originalHTML,
                expectedToken: undoEdit.expectedModificationToken
            )
            try await notes.showNote(id: undoEdit.noteID)
            let restoredNote = try await waitForNote(
                id: undoEdit.noteID,
                afterToken: undoEdit.expectedModificationToken
            )
            self.undoEdit = nil
            undoAvailable = false
            self.note = restoredNote
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    /// Apple Notes may acknowledge a body write before its selection query
    /// reflects the new body. Poll briefly so the next AI operation starts
    /// from the actual restored/replaced content and its current token.
    private func waitForNote(id: String, afterToken previousToken: String) async throws -> NoteSnapshot {
        var latest = try await notes.selectedNote()
        for attempt in 0..<4 {
            if latest.id == id && latest.modificationToken != previousToken { return latest }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(120)) }
            latest = try await notes.selectedNote()
        }
        return latest
    }

    func endSession() {
        // Session-only cleanup. This never calls NotesServing and therefore
        // cannot delete, replace, or create anything in Apple Notes.
        idleTask?.cancel()
        note = nil
        lastNoteSync = nil
        messages.removeAll(keepingCapacity: false)
        proposal = nil
        undoEdit = nil
        undoAvailable = false
        prompt = ""
        errorMessage = nil
        resetIdleTimer()
    }

    private func defaultPrompt(for action: NopiloteAction) -> String {
        switch action {
        case .ask: return ""
        case .summarize: return "Summarize this note and preserve the important details."
        case .outline: return "Turn this note into a clear logical outline."
        case .rewrite: return "Rewrite this note for clarity and organization."
        case .condense: return "Condense this note while preserving key information."
        case .expand: return "Expand this note into a more complete and useful version without inventing facts."
        case .polish: return "Polish the language and structure of this note."
        }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled else { return }
            self?.endSession()
        }
    }

    private func observeScreenLock() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func screenDidLock() { endSession() }

}
