import SwiftUI

@main
struct MessageVaultApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appInfo) { Button("About MessageVault") { model.showsAbout = true } }
                CommandGroup(after: .appInfo) {
                    Button(model.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") { model.checkForUpdates(manual: true) }
                        .disabled(model.isCheckingForUpdates)
                }
            }
        Settings { PrivacySettingsView().environmentObject(model).frame(width: 480, height: 260) }
    }
}

struct PrivacySettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("Privacy") {
                LabeledContent("Messages access", value: model.hasFullDiskAccess ? "Allowed" : "Not allowed")
                LabeledContent("Contacts", value: String(describing: model.contactsStatus).capitalized)
                Text("MessageVault has no network features. Database access is read-only, and temporary export files are removed after cancellation or failure.").foregroundStyle(.secondary)
            }
            HStack { Button("Full Disk Access Settings") { model.openFullDiskAccessSettings() }; Button("Request Contacts Access") { model.requestContacts() } }
        }.padding()
    }
}
