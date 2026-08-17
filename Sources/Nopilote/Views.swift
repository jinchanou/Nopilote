import Foundation
import SwiftUI

struct NopiloteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            noteScope
            Divider()
            content
            Divider()
            composer
        }
        .frame(minWidth: 390, idealWidth: 420, minHeight: 520, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.monitorCurrentNoteSelection() }
        .sheet(isPresented: $model.cloudConsentPending) { ConsentView() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nopilote")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(model.provider.name) · \(model.modelName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.undoAvailable {
                Button { Task { await model.undoLastEdit() } } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(model.isWorking)
                .help("Undo last Nopilote replacement")
            }
            Button { model.isPinned.toggle() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(model.isPinned ? "Unpin: stay below the active app" : "Pin: keep visible over other apps")
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Menu {
                Button("End session", systemImage: "rectangle.portrait.and.arrow.right") { model.endSession() }
                Divider()
                Button("Quit Nopilote", systemImage: "power") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(14)
    }

    private var noteScope: some View {
        HStack(spacing: 9) {
            Image(systemName: "eye")
                .foregroundStyle(model.note == nil ? .secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI is viewing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let note = model.note {
                    Text("Apple Notes › \(note.account) › \(note.folder) › \(note.title)")
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                    if !note.images.isEmpty {
                        let suffix = note.images.count == 1 ? "" : "s"
                        Label("\(note.images.count) image attachment\(suffix) available to vision models", systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let sync = model.lastNoteSync {
                        Text("Selection checked \(sync, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Using \(model.activeModelLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No unlocked note selected in Apple Notes")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button { Task { await model.showCurrentNoteInNotes() } } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .disabled(model.note == nil)
            .help("Show this note in Apple Notes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(model.note == nil ? 0 : 0.07))
    }

    @ViewBuilder private var content: some View {
        if let error = model.errorMessage, model.messages.isEmpty {
            AccessErrorView(message: error) {
                Task { await model.loadCurrentNote() }
            }
        } else if model.messages.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("Work with this note")
                    .font(.title2.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(NopiloteAction.allCases.filter { $0 != .ask }) { action in
                        Button {
                            model.selectedAction = action
                            Task { await model.send() }
                        } label: {
                            Label(action.title, systemImage: icon(for: action))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 30)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.note == nil || model.isWorking)
                    }
                }
                Spacer()
            }
            .padding(14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { message in
                            MessageView(message: message).id(message.id)
                        }
                        if model.isWorking { ProgressView().controlSize(.small) }
                    }
                    .padding(18)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if model.undoAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward").foregroundStyle(.tint)
                    Text("Last Nopilote replacement can be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await model.undoLastEdit() } } label: {
                        Text("Undo")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isWorking)
                }
            }
            if let error = model.errorMessage, !model.messages.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss")
                }
            }
            HStack {
                Picker("Action", selection: $model.selectedAction) {
                    ForEach(NopiloteAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Menu {
                    ForEach(AIProviderKind.allCases) { kind in
                        Button {
                            model.selectConfiguredProvider(kind)
                        } label: {
                            Label {
                                HStack {
                                    Text(kind.name)
                                    if kind == model.provider { Text("(current)").foregroundStyle(.secondary) }
                                }
                            } icon: {
                                Image(systemName: kind == model.provider ? "checkmark" : "")
                            }
                        }
                        .disabled(!model.hasAPIKey(for: kind))
                    }
                } label: {
                    Label("Model", systemImage: "cpu")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this note", text: $model.prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.send() } }
                Button { Task { await model.send() } } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.note == nil || model.isWorking || (!model.hasEnteredPrompt && model.selectedAction == .ask))
                .help("Send")
            }
        }
        .padding(14)
    }

    private func icon(for action: NopiloteAction) -> String {
        switch action {
        case .ask: "questionmark.bubble"
        case .summarize: "text.justify.left"
        case .outline: "list.bullet.indent"
        case .rewrite: "pencil.line"
        case .condense: "arrow.down.right.and.arrow.up.left"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .polish: "wand.and.sparkles"
        }
    }
}

private struct AccessErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Nopilote needs attention")
                .font(.headline)
            ScrollView {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
            .frame(minHeight: 100, maxHeight: .infinity)
            Button("Try again", action: retry)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "You" : "Nopilote")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FormattedMessageContent(content: message.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(message.role == .user ? 10 : 0)
        .background(message.role == .user ? Color.accentColor.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

}

private struct FormattedMessageContent: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [String] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let result = normalized
            .components(separatedBy: "\n\n")
            .flatMap { chunk in
                let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                return lines.reduce(into: [String]()) { output, line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        return
                    }
                    output.append(line)
                }
            }
        return result.isEmpty ? [content] : result
    }

    @ViewBuilder
    private func blockView(_ block: String) -> some View {
        let trimmed = block.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
            markdownText(trimmed)
                .font(.headline)
                .padding(.top, 3)
                .textSelection(.enabled)
        } else if let bullet = listItem(trimmed) {
            HStack(alignment: .top, spacing: 8) {
                Text(bullet.marker)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                markdownText(bullet.text)
                    .textSelection(.enabled)
            }
        } else if trimmed.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
                markdownText(String(trimmed.dropFirst(2)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else if trimmed == "---" || trimmed == "***" {
            Divider()
        } else {
            markdownText(block)
                .textSelection(.enabled)
        }
    }

    private func listItem(_ value: String) -> (marker: String, text: String)? {
        if value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("• ") {
            return ("•", String(value.dropFirst(2)))
        }
        var digits = ""
        for character in value {
            if character.isNumber { digits.append(character) } else { break }
        }
        guard !digits.isEmpty, value.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (digits + ".", String(value.dropFirst(digits.count + 2)))
    }

    private func markdownText(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full)) {
            return Text(attributed)
        }
        return Text(value.replacingOccurrences(of: "**", with: ""))
    }
}

struct ProposalView: View {
    @EnvironmentObject private var model: AppModel
    let proposal: EditProposal
    let showConversation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review changes").font(.title2.weight(.semibold))
                    Text(proposal.requiresNewNote ? "Complex formatting detected. The original will not be changed." : "Nothing is written until you confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: showConversation) {
                    Label("Conversation", systemImage: "bubble.left")
                }
                .help("Return to the conversation without closing this review")
                Button { model.discardProposal() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close")
            }
            HSplitView {
                diffColumn(title: "Original", text: proposal.originalPlainText)
                diffColumn(title: "Proposed", text: proposal.proposedPlainText)
            }
            HStack {
                Button("Discard", role: .cancel) { model.discardProposal() }
                Spacer()
                if !proposal.requiresNewNote {
                    Button("Create copy") { apply(copy: true) }
                        .disabled(model.isWorking)
                }
                Button(proposal.requiresNewNote ? "Create organized note" : "Replace note") { apply(copy: proposal.requiresNewNote) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func diffColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(10).background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func apply(copy: Bool) {
        Task {
            await model.applyProposal(createCopy: copy)
            // applyProposal clears the proposal only after a successful write.
            // The review window observes that state and closes on success. It
            // stays open on failure so the user can see and retry.
        }
    }
}

struct ConsentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.tint)
            Text("Cloud processing").font(.title2.weight(.semibold))
            Text("When you send a request, the visible current-note scope and your question are sent to your selected model provider. Nopilote keeps chat and note content only in memory and clears them when the session ends.")
            Text("Locked notes are never read. API keys stay in Nopilote's private local settings.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
                Button("I understand") { model.grantCloudConsent() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 430)
        .interactiveDismissDisabled()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Picker("Provider", selection: Binding(get: { model.provider }, set: model.selectProvider)) {
                ForEach(AIProviderKind.allCases) { Text($0.name).tag($0) }
            }
            TextField("Model", text: $model.modelName)
                .onSubmit { model.saveModelName() }
            SecureField(
                hasSavedKey ? "API key saved (enter a new key to replace it)" : "API key",
                text: $key
            )
            HStack {
                Spacer()
                if hasSavedKey {
                    Button("Remove") {
                        model.removeAPIKey()
                        hasSavedKey = false
                        key = ""
                        statusMessage = "API key removed from Nopilote's local settings."
                        statusIsError = false
                    }
                    .foregroundStyle(.red)
                }
                Button("Save") {
                    do {
                        try model.saveSettings(apiKey: key)
                        key = ""
                        hasSavedKey = true
                        statusMessage = "API key saved in Nopilote's private local settings."
                        statusIsError = false
                    } catch {
                        statusMessage = "Could not save API key: \(error.localizedDescription)"
                        statusIsError = true
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 300)
        .onAppear {
            // Showing configuration status does not read the secret field.
            hasSavedKey = model.hasStoredAPIKey
            statusIsError = false
            statusMessage = hasSavedKey ? "API key saved in Nopilote's private local settings." : nil
        }
        .onChange(of: model.provider) { _, _ in
            key = ""
            hasSavedKey = model.hasStoredAPIKey
            statusIsError = false
            statusMessage = hasSavedKey ? "Using \(model.activeModelLabel). API key saved for this provider." : "Using \(model.activeModelLabel). No API key saved for this provider."
        }
        .onChange(of: model.modelName) { _, _ in
            model.saveModelName()
        }
    }
}
