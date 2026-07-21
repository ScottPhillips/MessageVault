import AppKit
import Contacts
import Foundation
import SwiftUI

enum SidebarSort: String, CaseIterable, Identifiable {
    case recent = "Recent activity"
    case messages = "Message quantity"
    case attachments = "Attachment quantity"
    case name = "Name"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    @Published var snapshot: LibrarySnapshot?
    @Published var selectedPersonID: String?
    @Published var search = ""
    @Published var sidebarSort: SidebarSort = .recent
    @Published var sidebarAscending = false
    @Published var scope: PersonScope = .directOnly
    @Published var direction: DirectionFilter = .all
    @Published var useDateRange = false
    @Published var startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @Published var endDate = Date()
    @Published var selectedConversationIDs = Set<Int64>()
    @Published var limitToSelectedConversations = false
    @Published var categories = Set(ContentCategory.allCases)
    @Published var preflight: PreflightReport?
    @Published var progress: ExportProgress?
    @Published var exportedURL: URL?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var contactsStatus: CNAuthorizationStatus
    @Published var messagesAccessGranted = false
    @Published var showsAbout = false
    @Published var updatePresentation: UpdatePresentation?
    @Published var isCheckingForUpdates = false

    private let store: MessageStore
    private let contacts = ContactResolver()
    private let exporter = ArchiveExporter()
    private let updateService = UpdateService()
    private var exportTask: Task<Void, Never>?

    init(store: MessageStore = MessageStore()) {
        self.store = store
        self.contactsStatus = contacts.authorizationStatus
        self.messagesAccessGranted = store.hasFullDiskAccess
    }

    var hasFullDiskAccess: Bool { messagesAccessGranted }
    var selectedPerson: PersonRecord? { snapshot?.people.first { $0.id == selectedPersonID } }
    var filteredPeople: [PersonRecord] {
        let people = snapshot?.people ?? []
        let filtered = search.isEmpty ? people : people.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.handles.contains { $0.localizedCaseInsensitiveContains(search) } }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sidebarSort {
            case .recent:
                comparison = (lhs.latestMessageDate ?? .distantPast).compare(rhs.latestMessageDate ?? .distantPast)
            case .messages:
                comparison = lhs.messageCount == rhs.messageCount ? lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) : (lhs.messageCount < rhs.messageCount ? .orderedAscending : .orderedDescending)
            case .attachments:
                comparison = lhs.attachmentCount == rhs.attachmentCount ? lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) : (lhs.attachmentCount < rhs.attachmentCount ? .orderedAscending : .orderedDescending)
            case .name:
                comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            }
            return sidebarAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    var relevantConversations: [ConversationRecord] {
        guard let person = selectedPerson else { return [] }
        return (snapshot?.conversations ?? []).filter {
            let includesPerson = !Set($0.participantHandleIDs).isDisjoint(with: person.handleRowIDs)
            let matchesScope = scope != .directOnly || $0.participantHandleIDs.count == 1
            return includesPerson && matchesScope
        }
    }

    func loadLibrary(resolveContacts: Bool = true) {
        refreshMessagesAccess()
        guard messagesAccessGranted else { return }
        isLoading = true; errorMessage = nil; preflight = nil
        Task {
            do {
                var matches: [String: ContactMatch] = [:]
                if resolveContacts && contacts.authorizationStatus == .authorized {
                    let initial = try store.scan()
                    matches = try contacts.resolve(handles: initial.people.flatMap(\.handles))
                }
                snapshot = try store.scan(contactMatches: matches)
                contactsStatus = contacts.authorizationStatus
                if selectedPersonID == nil { selectedPersonID = snapshot?.people.first?.id }
            } catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    func refreshMessagesAccess() {
        messagesAccessGranted = store.hasFullDiskAccess
    }

    func requestContacts() {
        if contacts.authorizationStatus == .denied || contacts.authorizationStatus == .restricted {
            openContactsSettings()
            return
        }
        Task {
            do {
                let granted = try await contacts.requestAccess()
                contactsStatus = contacts.authorizationStatus
                if granted { loadLibrary() }
                else { openContactsSettings() }
            } catch {
                contactsStatus = contacts.authorizationStatus
                if contactsStatus == .denied || contactsStatus == .restricted { openContactsSettings() }
                else { errorMessage = "Contacts access could not be requested: \(error.localizedDescription)" }
            }
        }
    }

    func openContactsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    func quitApp() { NSApplication.shared.terminate(nil) }

    func checkForUpdates(manual: Bool) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task {
            do {
                let result = try await updateService.check(currentVersion: Self.appVersion)
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                switch result {
                case .available(let release): updatePresentation = .available(release)
                case .upToDate(let release): if manual { updatePresentation = .upToDate(release) }
                }
            } catch {
                if manual { updatePresentation = .failed(error.localizedDescription) }
            }
            isCheckingForUpdates = false
        }
    }

    func performAutomaticUpdateCheckIfNeeded() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        checkForUpdates(manual: false)
    }

    func makeFilter() throws -> ExportFilter {
        guard let person = selectedPerson else { throw MessageVaultError.noPersonSelected }
        return ExportFilter(person: person, scope: scope, direction: direction, startDate: useDateRange ? startDate : nil, endDate: useDateRange ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) : nil, conversationIDs: limitToSelectedConversations ? selectedConversationIDs : [], categories: categories)
    }

    func runPreflight() {
        isLoading = true; errorMessage = nil; exportedURL = nil
        Task {
            do { preflight = try store.preflight(filter: makeFilter()) }
            catch { errorMessage = error.localizedDescription; preflight = nil }
            isLoading = false
        }
    }

    func chooseDestinationAndExport() {
        guard let report = preflight, let filter = try? makeFilter() else { return }
        let panel = NSSavePanel()
        panel.title = "Choose export folder"
        panel.nameFieldStringValue = "Messages Export - \(filter.person.displayName)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true; errorMessage = nil
        exportTask = Task {
            do {
                let result = try await exporter.export(report: report, filter: filter, conversations: snapshot?.conversations ?? [], to: url) { update in
                    Task { @MainActor in self.progress = update }
                }
                exportedURL = result
            } catch is CancellationError { errorMessage = "Export cancelled. Partial files were removed." }
            catch { errorMessage = error.localizedDescription }
            isExporting = false; exportTask = nil
        }
    }

    func cancelExport() { exportTask?.cancel() }
    func revealExport() { if let exportedURL { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) } }
    func openArchive() { if let exportedURL { NSWorkspace.shared.open(exportedURL.appendingPathComponent("index.html")) } }
}

enum UpdatePresentation: Identifiable {
    case available(GitHubRelease)
    case upToDate(GitHubRelease)
    case failed(String)

    var id: String {
        switch self {
        case .available(let release): "available-\(release.tagName)"
        case .upToDate(let release): "current-\(release.tagName)"
        case .failed(let message): "failed-\(message)"
        }
    }
}
