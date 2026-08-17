import Foundation

struct NoteImage: Equatable, Sendable {
    let name: String
    let mimeType: String
    let base64Data: String
}

struct NoteSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
    let folder: String
    let folderID: String
    let html: String
    let plainText: String
    let modificationDate: Date?
    let modificationToken: String
    let isLocked: Bool
    let isShared: Bool
    let images: [NoteImage]

    init(
        id: String,
        title: String,
        account: String,
        folder: String,
        folderID: String,
        html: String,
        plainText: String,
        modificationDate: Date?,
        modificationToken: String,
        isLocked: Bool,
        isShared: Bool,
        images: [NoteImage] = []
    ) {
        self.id = id
        self.title = title
        self.account = account
        self.folder = folder
        self.folderID = folderID
        self.html = html
        self.plainText = plainText
        self.modificationDate = modificationDate
        self.modificationToken = modificationToken
        self.isLocked = isLocked
        self.isShared = isShared
        self.images = images
    }

    var hasComplexFormatting: Bool {
        NoteHTML.containsComplexFormatting(html)
    }
}

enum AIProviderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case qwen
    case zhipu

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .qwen: "Qwen"
        case .zhipu: "Zhipu"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5-mini"
        case .anthropic: "claude-sonnet-4-5"
        case .gemini: "gemini-2.5-flash"
        case .deepSeek: "deepseek-chat"
        case .qwen: "qwen-plus"
        case .zhipu: "glm-4.5-flash"
        }
    }

    var keychainAccount: String { "provider.\(rawValue).api-key" }
}

enum NoteAccessError: LocalizedError, Equatable {
    case noSelection
    case locked
    case automationDenied(String)
    case scriptFailed(String)
    case malformedResponse
    case imageReadFailed(String)
    case changedSincePreview
    case unsupportedFormatting

    var errorDescription: String? {
        switch self {
        case .noSelection: return "Select a note in Apple Notes first."
        case .locked: return "Locked notes are never read or changed. Unlocking a note does not make it available to this app."
        case .automationDenied(let detail):
            let prefix = "Nopilote is not allowed to control Apple Notes. Click Try again and approve the macOS permission request."
            let cleanedDetail = detail
                .replacingOccurrences(of: "Notes access failed. Allow Nopilote in System Settings > Privacy & Security > Automation.", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanedDetail.isEmpty ? prefix : "\(prefix) Details: \(cleanedDetail)"
        case .scriptFailed(let detail): return "Apple Notes returned an error. \(detail)"
        case .malformedResponse: return "Apple Notes returned an unexpected response."
        case .imageReadFailed(let detail):
            let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty
                ? "Apple Notes contains images, but Nopilote could not read the image data."
                : "Apple Notes contains images, but Nopilote could not read the image data. \(cleaned)"
        case .changedSincePreview: return "The note changed after this preview was created. Refresh and try again."
        case .unsupportedFormatting: return "This note contains complex formatting. Create a separate organized note instead."
        }
    }
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    let content: String

    init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

enum NopiloteAction: String, CaseIterable, Identifiable, Sendable {
    case ask
    case summarize
    case outline
    case rewrite
    case condense
    case expand
    case polish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .summarize: "Summarize"
        case .outline: "Outline"
        case .rewrite: "Rewrite"
        case .condense: "Condense"
        case .expand: "Expand"
        case .polish: "Polish"
        }
    }

    enum ProposalPolicy {
        case forbidden
        case optional
        case required
    }

    var proposalPolicy: ProposalPolicy {
        switch self {
        // Ask can be conversational or an edit request; the model decides
        // from the user's explicit intent.
        case .ask: .optional
        case .summarize: .forbidden
        case .outline, .rewrite, .condense, .expand, .polish: .required
        }
    }

    var allowsProposal: Bool { proposalPolicy != .forbidden }
    var requiresProposal: Bool { proposalPolicy == .required }
}

struct AIResponse: Codable, Equatable, Sendable {
    let answer: String
    let proposal: NoteProposalContent?
}

struct NoteProposalContent: Codable, Equatable, Sendable {
    let title: String
    let blocks: [DocumentBlock]
}

struct DocumentBlock: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heading
        case paragraph
        case bulletList
        case numberedList
        case quote
        case code
        case checklist
        case table
        case divider
        case callout
    }

    let kind: Kind
    let text: String?
    let items: [String]?
    let level: Int?
    let rows: [[String]]?
    let checked: [Bool]?

    init(
        kind: Kind,
        text: String?,
        items: [String]?,
        level: Int?,
        rows: [[String]]? = nil,
        checked: [Bool]? = nil
    ) {
        self.kind = kind
        self.text = text
        self.items = items
        self.level = level
        self.rows = rows
        self.checked = checked
    }
}

struct EditProposal: Identifiable, Equatable, Sendable {
    let id = UUID()
    let noteID: String
    let expectedModificationToken: String
    let originalTitle: String
    let originalPlainText: String
    let proposedTitle: String
    let proposedPlainText: String
    let proposedHTML: String
    let requiresNewNote: Bool
}

struct UndoEdit: Equatable, Sendable {
    let noteID: String
    let originalHTML: String
    let expectedModificationToken: String
}

enum AppError: LocalizedError {
    case missingAPIKey
    case apiKeyUnavailable(String)
    case invalidProviderResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an API key for the selected provider in Settings."
        case .apiKeyUnavailable(let detail):
            "The API key for the selected provider could not be read from Nopilote's local settings. \(detail)"
        case .invalidProviderResponse:
            "The model returned an empty, incomplete, or malformed response. No note changes were made. Try again, or use a model with a larger output limit."
        case .provider(let message): message
        }
    }
}
