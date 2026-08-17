import AppKit
import Foundation

protocol NotesServing: Sendable {
    func selectedNoteID() async throws -> String
    func selectedNote() async throws -> NoteSnapshot
    func refreshMetadata(id: String) async throws -> (isLocked: Bool, modificationToken: String)
    func replaceNote(id: String, html: String, expectedToken: String) async throws
    func createNote(folderID: String, html: String) async throws -> String
    func showNote(id: String) async throws
}

actor AppleNotesService: NotesServing {
    private let runner: AppleScriptRunning

    init(runner: AppleScriptRunning = AppleScriptRunner()) {
        self.runner = runner
    }

    func selectedNoteID() async throws -> String {
        try await requestAutomationPermission()
        let output = try runner.run(Self.selectedNoteIDScript)
        if output == "NONE" { throw NoteAccessError.noSelection }
        if output == "LOCKED" { throw NoteAccessError.locked }
        guard output.hasPrefix("OK\n") else { throw NoteAccessError.malformedResponse }
        return try decode(String(output.dropFirst(3)))
    }

    func selectedNote() async throws -> NoteSnapshot {
        try await requestAutomationPermission()
        let output = try runner.run(Self.selectedNoteScript)
        let fields = output.components(separatedBy: "\n")
        guard let status = fields.first else { throw NoteAccessError.malformedResponse }
        if status == "NONE" { throw NoteAccessError.noSelection }
        if status == "LOCKED" { throw NoteAccessError.locked }
        if status == "IMAGE_ERROR" {
            let detail = fields.dropFirst().first.flatMap { try? decode($0) } ?? ""
            throw NoteAccessError.imageReadFailed(detail)
        }
        guard status == "OK", fields.count >= 11 else { throw NoteAccessError.malformedResponse }

        var images: [NoteImage] = []
        if fields.count > 11, let imageCount = Int(fields[11]) {
            var index = 12
            for _ in 0..<imageCount where index + 2 < fields.count {
                let name = try decode(fields[index])
                let mimeType = fields[index + 1]
                let base64Data = fields[index + 2]
                guard !base64Data.isEmpty, Data(base64Encoded: base64Data) != nil else {
                    throw NoteAccessError.imageReadFailed("The attachment \(name) was empty or invalid.")
                }
                images.append(NoteImage(name: name, mimeType: mimeType, base64Data: base64Data))
                index += 3
            }
        }

        let modificationToken = try decode(fields[7])
        return NoteSnapshot(
            id: try decode(fields[1]),
            title: try decode(fields[2]),
            account: try decode(fields[3]),
            folder: try decode(fields[4]),
            folderID: try decode(fields[10]),
            html: try decode(fields[5]),
            plainText: try decode(fields[6]),
            modificationDate: ISO8601DateFormatter().date(from: modificationToken),
            modificationToken: modificationToken,
            isLocked: fields[8] == "true",
            isShared: fields[9] == "true",
            images: images
        )
    }

    func refreshMetadata(id: String) async throws -> (isLocked: Bool, modificationToken: String) {
        try await requestAutomationPermission()
        let output = try runner.run(Self.metadataScript(noteID: id))
        let fields = output.components(separatedBy: "\n")
        guard fields.count >= 3, fields[0] == "OK" else { throw NoteAccessError.malformedResponse }
        return (fields[1] == "true", fields[2])
    }

    func replaceNote(id: String, html: String, expectedToken: String) async throws {
        try await requestAutomationPermission()
        let output = try runner.run(Self.replaceScript(noteID: id, html: html, expectedToken: expectedToken))
        switch output {
        case "OK": return
        case "LOCKED": throw NoteAccessError.locked
        case "CHANGED": throw NoteAccessError.changedSincePreview
        default: throw NoteAccessError.malformedResponse
        }
    }

    func createNote(folderID: String, html: String) async throws -> String {
        try await requestAutomationPermission()
        let output = try runner.run(Self.createScript(folderID: folderID, html: html))
        guard output.hasPrefix("OK\n") else { throw NoteAccessError.malformedResponse }
        return String(output.dropFirst(3))
    }

    func showNote(id: String) async throws {
        try await requestAutomationPermission()
        let output = try runner.run(Self.showScript(noteID: id))
        guard output == "OK" else { throw NoteAccessError.malformedResponse }
    }

    private func decode(_ encoded: String) throws -> String {
        guard let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8) else {
            throw NoteAccessError.malformedResponse
        }
        return value
    }

    private func requestAutomationPermission() async throws {
        let status = await Task.detached(priority: .userInitiated) {
            AppleNotesAutomationPermission.request()
        }.value
        guard status == noErr else {
            throw NoteAccessError.automationDenied(AppleNotesAutomationPermission.message(for: status))
        }
    }

    private static let helpers = #"""
        use framework "Foundation"
        use scripting additions

        on b64(value)
            set sourceText to current application's NSString's stringWithString:(value as text)
            set sourceData to sourceText's dataUsingEncoding:(current application's NSUTF8StringEncoding)
            return (sourceData's base64EncodedStringWithOptions:0) as text
        end b64

        on b64Data(value)
            try
                return (value's base64EncodedStringWithOptions:0) as text
            on error
                return ""
            end try
        end b64Data

        on readAttachmentData(currentAttachment, attachmentName)
            -- Notes exposes attachment contents as a hidden file reference,
            -- not reliably as NSData. Export it first, then read the bytes
            -- through Foundation so the model receives the actual image.
            set safeName to "nopilote-" & (current application's NSUUID's UUID()'s UUIDString() as text)
            set extensionText to ""
            try
                set oldDelimiters to AppleScript's text item delimiters
                set AppleScript's text item delimiters to "."
                set extensionText to (last text item of (attachmentName as text)) as text
                set AppleScript's text item delimiters to oldDelimiters
            end try
            set tempPOSIXPath to ((POSIX path of (path to temporary items)) & safeName & "." & extensionText)
            set tempFile to POSIX file tempPOSIXPath
            try
                tell application "Notes" to save currentAttachment in tempFile
                set attachmentData to current application's NSData's dataWithContentsOfFile:tempPOSIXPath
                if attachmentData is missing value then error "Notes returned no bytes"
                set encodedData to (attachmentData's base64EncodedStringWithOptions:0) as text
                current application's NSFileManager's defaultManager()'s removeItemAtPath:tempPOSIXPath |error|:(missing value)
                return encodedData
            on error errorText
                try
                    current application's NSFileManager's defaultManager()'s removeItemAtPath:tempPOSIXPath |error|:(missing value)
                end try
                error errorText
            end try
        end readAttachmentData

        on imageMime(filename)
            set extensionText to ""
            try
                set oldDelimiters to AppleScript's text item delimiters
                set AppleScript's text item delimiters to "."
                set extensionText to (last text item of (filename as text)) as text
                set AppleScript's text item delimiters to oldDelimiters
                set extensionText to my lowercase(extensionText)
            end try
            if extensionText is "jpg" or extensionText is "jpeg" then return "image/jpeg"
            if extensionText is "png" then return "image/png"
            if extensionText is "gif" then return "image/gif"
            if extensionText is "webp" then return "image/webp"
            if extensionText is "heic" or extensionText is "heif" then return "image/heic"
            return ""
        end imageMime

        on lowercase(value)
            set lowercaseString to current application's NSString's stringWithString:(value as text)
            return (lowercaseString's lowercaseString()) as text
        end lowercase

        on isoDate(value)
            set formatter to current application's NSISO8601DateFormatter's alloc()'s init()
            return (formatter's stringFromDate:value) as text
        end isoDate

        on accountNameFor(aFolder)
            tell application "Notes"
                set currentContainer to aFolder
                repeat
                    if (class of currentContainer as text) is "account" then return name of currentContainer
                    try
                        set parentContainer to container of currentContainer
                    on error
                        return name of currentContainer
                    end try
                    set currentContainer to parentContainer
                end repeat
            end tell
        end accountNameFor
        """# + "\n"

    private static let selectedNoteIDScript = helpers + #"""
        tell application "Notes"
            set picked to selection
            if (count of picked) is 0 then return "NONE"
            set targetNote to item 1 of picked
            if password protected of targetNote then return "LOCKED"
            set noteID to id of targetNote
        end tell
        return "OK" & linefeed & b64(noteID)
        """#

    private static let selectedNoteScript = helpers + #"""
        tell application "Notes"
            set picked to selection
            if (count of picked) is 0 then return "NONE"
            set targetNote to item 1 of picked
            if password protected of targetNote then return "LOCKED"

            -- Body access deliberately occurs only after the lock check above.
            set noteID to id of targetNote
            set noteTitle to name of targetNote
            set noteFolderObject to container of targetNote
            set noteAccount to my accountNameFor(noteFolderObject)
            set noteFolder to name of noteFolderObject
            set noteFolderID to id of noteFolderObject
            set noteBody to body of targetNote
            set noteText to plaintext of targetNote
            set modifiedAt to modification date of targetNote
            set sharedFlag to shared of targetNote
        end tell

        set imageLines to ""
        set imageCount to 0
        set imageFailure to ""
        tell application "Notes"
            repeat with currentAttachment in (every attachment of targetNote)
                set attachmentName to name of currentAttachment
                set attachmentMime to my imageMime(attachmentName)
                if attachmentMime is not "" then
                    try
                        set encodedData to my readAttachmentData(currentAttachment, attachmentName)
                        if encodedData is not "" then
                            set imageCount to imageCount + 1
                            set imageLines to imageLines & linefeed & my b64(attachmentName) & linefeed & attachmentMime & linefeed & encodedData
                        end if
                    on error errorText
                        set imageFailure to errorText as text
                    end try
                end if
            end repeat
        end tell
        if imageFailure is not "" then return "IMAGE_ERROR" & linefeed & b64(imageFailure)
        return "OK" & linefeed & b64(noteID) & linefeed & b64(noteTitle) & linefeed & b64(noteAccount) & linefeed & b64(noteFolder) & linefeed & b64(noteBody) & linefeed & b64(noteText) & linefeed & b64(isoDate(modifiedAt)) & linefeed & "false" & linefeed & (sharedFlag as text) & linefeed & b64(noteFolderID) & linefeed & (imageCount as text) & imageLines
        """#

    private static func metadataScript(noteID: String) -> String {
        helpers + """
        set wantedID to \(literal(noteID))
        tell application \"Notes\"
            set matches to every note whose id is wantedID
            if (count of matches) is 0 then return \"MISSING\"
            set targetNote to item 1 of matches
            set lockFlag to password protected of targetNote
            set modifiedAt to modification date of targetNote
        end tell
        return \"OK\" & linefeed & (lockFlag as text) & linefeed & isoDate(modifiedAt)
        """
    }

    private static func replaceScript(noteID: String, html: String, expectedToken: String) -> String {
        helpers + """
        set wantedID to \(literal(noteID))
        set newBody to \(literal(html))
        set expectedModifiedAt to \(literal(expectedToken))
        tell application \"Notes\"
            set matches to every note whose id is wantedID
            if (count of matches) is 0 then return \"MISSING\"
            set targetNote to item 1 of matches
            if password protected of targetNote then return \"LOCKED\"
            if my isoDate(modification date of targetNote) is not expectedModifiedAt then return \"CHANGED\"
            set body of targetNote to newBody
        end tell
        return \"OK\"
        """
    }

    private static func createScript(folderID: String, html: String) -> String {
        helpers + """
        set wantedFolderID to \(literal(folderID))
        set newBody to \(literal(html))
        tell application \"Notes\"
            set foldersFound to every folder whose id is wantedFolderID
            if (count of foldersFound) is 0 then return \"MISSING\"
            set createdNote to make new note at item 1 of foldersFound with properties {body:newBody}
            return \"OK\" & linefeed & id of createdNote
        end tell
        """
    }

    private static func showScript(noteID: String) -> String {
        helpers + """
        set wantedID to \(literal(noteID))
        tell application \"Notes\"
            set matches to every note whose id is wantedID
            if (count of matches) is 0 then return \"MISSING\"
            show item 1 of matches
            activate
        end tell
        return \"OK\"
        """
    }

    private static func literal(_ value: String) -> String {
        let data = Data(value.utf8).base64EncodedString()
        return "((current application's NSString's alloc()'s initWithData:((current application's NSData's alloc()'s initWithBase64EncodedString:\"\(data)\" options:0)) encoding:(current application's NSUTF8StringEncoding)) as text)"
    }

    static var scriptsForCompilationTesting: [String] {
        [
            selectedNoteIDScript,
            selectedNoteScript,
            metadataScript(noteID: "test-note"),
            replaceScript(noteID: "test-note", html: "<p>test</p>", expectedToken: "test-token"),
            createScript(folderID: "test-folder", html: "<p>test</p>"),
            showScript(noteID: "test-note")
        ]
    }
}

private enum AppleNotesAutomationPermission {
    static func request() -> OSStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.Notes"
        let createStatus = bundleID.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                bundleID.utf8.count,
                &target
            )
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            true
        )
    }

    static func message(for status: OSStatus) -> String {
        switch status {
        case OSStatus(errAEEventNotPermitted):
            "Permission was denied."
        case OSStatus(errAEEventWouldRequireUserConsent):
            "macOS needs your approval."
        case OSStatus(procNotFound):
            "Apple Notes is not running. Open Apple Notes, then try again."
        default:
            "macOS returned error \(status)."
        }
    }
}

protocol AppleScriptRunning: Sendable {
    func run(_ source: String) throws -> String
}

struct AppleScriptRunner: AppleScriptRunning {
    func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NoteAccessError.malformedResponse
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.int32Value
            if number == OSStatus(errAEEventNotPermitted) || number == OSStatus(errAEEventWouldRequireUserConsent) {
                throw NoteAccessError.automationDenied(message)
            }
            throw NoteAccessError.scriptFailed(message)
        }
        return result.stringValue ?? ""
    }
}
