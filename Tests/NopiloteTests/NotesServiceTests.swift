import XCTest
@testable import Nopilote

final class NotesServiceTests: XCTestCase {
    func testAllAppleNotesScriptsCompile() {
        for (index, source) in AppleNotesService.scriptsForCompilationTesting.enumerated() {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            XCTAssertNotNil(script, "Could not create script \(index)")
            let compiled = script?.compileAndReturnError(&error) == true
            let range = (error?[NSAppleScript.errorRange] as? NSValue)?.rangeValue ?? NSRange(location: 0, length: 0)
            let contextRange = NSRange(location: max(0, range.location - 50), length: min((source as NSString).length - max(0, range.location - 50), range.length + 100))
            let context = (source as NSString).substring(with: contextRange)
            XCTAssertTrue(compiled, "Script \(index): \(error?.description ?? "unknown compilation error") near \(context)")
        }
    }

    func testAutomationErrorDoesNotDuplicateGuidance() {
        let detail = "Notes access failed. Allow Nopilote in System Settings > Privacy & Security > Automation. Apple Notes denied the automation request."
        let message = NoteAccessError.automationDenied(detail).localizedDescription

        XCTAssertEqual(message.components(separatedBy: "Notes access failed").count, 1)
        XCTAssertTrue(message.contains("Apple Notes denied the automation request."))
    }

    func testScriptFailureIsNotReportedAsPermissionFailure() {
        let message = NoteAccessError.scriptFailed("Expected end of line.").localizedDescription

        XCTAssertEqual(message, "Apple Notes returned an error. Expected end of line.")
        XCTAssertFalse(message.contains("permission"))
    }

    func testLockedSelectionNeverReturnsContent() async {
        let service = AppleNotesService(runner: StubRunner(output: "LOCKED"))

        do {
            _ = try await service.selectedNote()
            XCTFail("Expected locked error")
        } catch let error as NoteAccessError {
            XCTAssertEqual(error, .locked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParsesSelectedNoteProtocol() async throws {
        let values = ["id", "Title", "iCloud", "Folder", "<h1>Title</h1>", "Title", "2026-08-13T00:00:00Z"]
            .map { Data($0.utf8).base64EncodedString() }
        let folderID = Data("folder-id".utf8).base64EncodedString()
        let output = (["OK"] + values + ["false", "true", folderID]).joined(separator: "\n")
        let service = AppleNotesService(runner: StubRunner(output: output))

        let note = try await service.selectedNote()

        XCTAssertEqual(note.id, "id")
        XCTAssertEqual(note.account, "iCloud")
        XCTAssertEqual(note.folderID, "folder-id")
        XCTAssertEqual(note.plainText, "Title")
        XCTAssertTrue(note.isShared)
        XCTAssertFalse(note.isLocked)
    }

    func testParsesImageAttachmentsFromSelectedNoteProtocol() async throws {
        let values = ["id", "Title", "iCloud", "Folder", "<p>Title</p>", "Title", "2026-08-13T00:00:00Z"]
            .map { Data($0.utf8).base64EncodedString() }
        let folderID = Data("folder-id".utf8).base64EncodedString()
        let imageName = Data("photo.png".utf8).base64EncodedString()
        let output = ([("OK"), values[0], values[1], values[2], values[3], values[4], values[5], values[6], "false", "false", folderID, "1", imageName, "image/png", "aGVsbG8="]).joined(separator: "\n")
        let service = AppleNotesService(runner: StubRunner(output: output))

        let note = try await service.selectedNote()

        XCTAssertEqual(note.images.count, 1)
        XCTAssertEqual(note.images[0].name, "photo.png")
        XCTAssertEqual(note.images[0].mimeType, "image/png")
        XCTAssertEqual(note.images[0].base64Data, "aGVsbG8=")
    }

    func testImageReadFailureIsSurfacedInsteadOfSilentlyDroppingAttachment() async {
        let detail = Data("attachment export failed".utf8).base64EncodedString()
        let service = AppleNotesService(runner: StubRunner(output: "IMAGE_ERROR\n\(detail)"))

        do {
            _ = try await service.selectedNote()
            XCTFail("Expected image read failure")
        } catch let error as NoteAccessError {
            XCTAssertEqual(error, .imageReadFailed("attachment export failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyImageDataIsRejected() async {
        let values = ["id", "Title", "iCloud", "Folder", "<p>Title</p>", "Title", "2026-08-13T00:00:00Z"]
            .map { Data($0.utf8).base64EncodedString() }
        let folderID = Data("folder-id".utf8).base64EncodedString()
        let imageName = Data("photo.png".utf8).base64EncodedString()
        let output = (["OK"] + values + ["false", "false", folderID, "1", imageName, "image/png", ""]).joined(separator: "\n")
        let service = AppleNotesService(runner: StubRunner(output: output))

        do {
            _ = try await service.selectedNote()
            XCTFail("Expected invalid image data failure")
        } catch let error as NoteAccessError {
            XCTAssertEqual(error, .imageReadFailed("The attachment photo.png was empty or invalid."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct StubRunner: AppleScriptRunning {
    let output: String
    func run(_ source: String) throws -> String { output }
}
