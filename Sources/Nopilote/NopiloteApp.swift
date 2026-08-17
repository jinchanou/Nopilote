import AppKit
import SwiftUI

@main
struct NopiloteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView().environmentObject(appDelegate.model)
        }
    }
}
