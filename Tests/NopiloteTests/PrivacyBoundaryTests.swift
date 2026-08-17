import Foundation
import XCTest
@testable import Nopilote

final class PrivacyBoundaryTests: XCTestCase {
    func testProductionEntitlementsOnlyAllowAppleNotesAutomation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("AppBundle/Nopilote.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true)
        XCTAssertEqual(
            plist["com.apple.security.temporary-exception.apple-events"] as? [String],
            ["com.apple.Notes"]
        )

        let forbiddenKeys = [
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.device.camera",
            "com.apple.security.device.microphone",
            "com.apple.security.personal-information.addressbook",
            "com.apple.security.personal-information.calendars",
            "com.apple.security.automation.apple-events"
        ]
        for key in forbiddenKeys {
            XCTAssertNil(plist[key], "Unexpected entitlement: \(key)")
        }
    }
}
