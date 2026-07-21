import Contacts
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !model.hasFullDiskAccess { permissionView }
            else if model.snapshot == nil { loadingView }
            else { libraryView }
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("MessageVault", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }
        .onAppear { model.refreshMessagesAccess(); if model.hasFullDiskAccess && model.snapshot == nil { model.loadLibrary() }; model.performAutomaticUpdateCheckIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshMessagesAccess(); if model.hasFullDiskAccess && model.snapshot == nil { model.loadLibrary() } }
        }
        .onChange(of: model.selectedPersonID) { _, _ in
            model.limitToSelectedConversations = false
            model.selectedConversationIDs.removeAll()
            model.preflight = nil
        }
        .onChange(of: model.scope) { _, _ in
            model.limitToSelectedConversations = false
            model.selectedConversationIDs.removeAll()
            model.preflight = nil
        }
        .sheet(isPresented: $model.showsAbout) { AboutView() }
        .sheet(item: $model.updatePresentation) { UpdateResultView(presentation: $0) }
    }

    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 52)).foregroundStyle(.blue)
            Text("Allow access to your Messages library").font(.largeTitle.bold())
            Text("MessageVault needs Full Disk Access to read Apple’s local Messages database and attachments. It opens them read-only, works entirely offline, and never changes your conversations.").multilineTextAlignment(.center).frame(maxWidth: 560)
            VStack(alignment: .leading, spacing: 8) {
                Label("Open System Settings", systemImage: "1.circle.fill")
                Label("Enable MessageVault under Privacy & Security › Full Disk Access", systemImage: "2.circle.fill")
                Label("Quit and reopen MessageVault after enabling access", systemImage: "3.circle.fill")
            }
            HStack {
                Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }.buttonStyle(.borderedProminent)
                Button("Check Again") { model.refreshMessagesAccess(); if model.hasFullDiskAccess { model.loadLibrary() } }
                Button("Quit MessageVault") { model.quitApp() }
            }
            Text("If MessageVault is already listed and enabled, remove it with the minus button, add the copy in your Applications folder again, enable it, then quit and reopen the app.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 600)
            Text("Apple does not provide a public Messages export API. Compatibility relies on Apple’s undocumented local database format.").font(.caption).foregroundStyle(.secondary)
        }.padding(48)
    }

    private var loadingView: some View {
        VStack(spacing: 16) { ProgressView(); Text(model.isLoading ? "Scanning local Messages…" : "Ready to scan"); if !model.isLoading { Button("Scan Messages") { model.loadLibrary() } } }
    }

    private var libraryView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(model.filteredPeople, selection: $model.selectedPersonID) { person in
                    HStack(spacing: 10) {
                        ZStack { Circle().fill(.blue.gradient.opacity(0.18)); Text(initials(person.displayName)).font(.caption.bold()).foregroundStyle(.blue) }.frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(person.displayName).fontWeight(.medium).lineLimit(1); Spacer(); if let date = person.latestMessageDate { Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.tertiary) } }
                            Text("\(person.messageCount.formatted()) messages · \(person.attachmentCount.formatted()) files").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 3).tag(person.id)
                }
                Divider()
                libraryFooter.padding(12)
            }
            .searchable(text: $model.search, prompt: "People or addresses")
            .navigationTitle("People")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Sort", selection: $model.sidebarSort) { ForEach(SidebarSort.allCases) { Text($0.rawValue).tag($0) } }
                        Divider()
                        Picker("Direction", selection: $model.sidebarAscending) { Text("Ascending").tag(true); Text("Descending").tag(false) }
                    } label: { Label("Sort people", systemImage: "arrow.up.arrow.down") }
                }
            }
        } detail: {
            if let person = model.selectedPerson { exportConfiguration(person) }
            else { ContentUnavailableView("Choose a person", systemImage: "person.crop.circle") }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var libraryFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = model.snapshot {
                Text("Local history").font(.caption.bold())
                Text(dateSpan(snapshot)).font(.caption).foregroundStyle(.secondary)
                Text("\(snapshot.messageCount.formatted()) messages · \(snapshot.attachmentCount.formatted()) attachments").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Button("Rescan") { model.loadLibrary() }; Spacer(); if model.contactsStatus != .authorized { Button(model.contactsStatus == .denied ? "Contacts Settings" : "Use Contacts") { model.requestContacts() } } }
        }
    }

    private func exportConfiguration(_ person: PersonRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) { Text(person.displayName).font(.largeTitle.bold()); Text(person.handles.joined(separator: " · ")).foregroundStyle(.secondary).textSelection(.enabled) }
                scopeSection
                dateAndDirection
                contentTypes
                conversations
                if let report = model.preflight { preflightView(report) }
                HStack {
                    Button("Review Export") { model.runPreflight() }.buttonStyle(.borderedProminent).disabled(model.isLoading || model.categories.isEmpty || (model.limitToSelectedConversations && model.selectedConversationIDs.isEmpty))
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.exportedURL != nil { Button("Reveal in Finder") { model.revealExport() }; Button("Open Archive") { model.openArchive() } }
                }
            }.padding(28).frame(maxWidth: 960, alignment: .leading)
        }.navigationTitle("Export")
    }

    private var scopeSection: some View {
        filterCard(title: "Scope", subtitle: "Choose how this person appears in group conversations", icon: "person.2") {
            Picker("Include", selection: $model.scope) { ForEach(PersonScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Text(scopeDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scopeDescription: String {
        switch model.scope {
        case .directOnly: "Only one-to-one conversations with this person."
        case .allSharedHistory: "Direct conversations and complete group chats containing this person."
        case .onlyTheirMessages: "Only messages authored by this person, with the conversation name retained."
        }
    }

    private var dateAndDirection: some View {
        filterCard(title: "Time & direction", subtitle: "Limit the export without changing Messages", icon: "calendar") {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Picker("Direction", selection: $model.direction) { ForEach(DirectionFilter.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 260)
                Divider().frame(height: 24)
                Toggle("Custom date range", isOn: $model.useDateRange)
                if model.useDateRange { DatePicker("From", selection: $model.startDate, displayedComponents: .date).labelsHidden(); Image(systemName: "arrow.right").foregroundStyle(.tertiary); DatePicker("Through", selection: $model.endDate, in: model.startDate..., displayedComponents: .date).labelsHidden() }
                Spacer()
            }
        }
    }

    private var contentTypes: some View {
        filterCard(title: "Content", subtitle: "Every selected attachment is copied in its original format", icon: "square.grid.2x2") {
            HStack { Button("Select All") { model.categories = Set(ContentCategory.allCases) }.buttonStyle(.link); Button("Clear") { model.categories.removeAll() }.buttonStyle(.link); Spacer(); Text("\(model.categories.count) of \(ContentCategory.allCases.count) selected").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                ForEach(ContentCategory.allCases) { category in
                    Toggle(isOn: Binding(get: { model.categories.contains(category) }, set: { enabled in if enabled { model.categories.insert(category) } else { model.categories.remove(category) } })) {
                        Label(category.title, systemImage: contentIcon(category)).frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.button).buttonStyle(.bordered).tint(model.categories.contains(category) ? .blue : .secondary)
                }
            }
        }
    }

    private var conversations: some View {
        filterCard(title: "Conversations", subtitle: "Choose which conversations supply the selected content", icon: "bubble.left.and.bubble.right") {
            Picker("Conversation selection", selection: $model.limitToSelectedConversations) {
                Text("All matching conversations").tag(false)
                Text("Choose specific conversations").tag(true)
            }.pickerStyle(.segmented).labelsHidden()

            if model.limitToSelectedConversations {
                HStack {
                    Button("Select All") { model.selectedConversationIDs = Set(model.relevantConversations.map(\.id)) }.buttonStyle(.link)
                    Button("Clear") { model.selectedConversationIDs.removeAll() }.buttonStyle(.link)
                    Spacer()
                    Text("\(model.selectedConversationIDs.count) of \(model.relevantConversations.count) selected").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.relevantConversations) { chat in
                    Toggle(isOn: Binding(get: { model.selectedConversationIDs.contains(chat.id) }, set: { if $0 { model.selectedConversationIDs.insert(chat.id) } else { model.selectedConversationIDs.remove(chat.id) } })) {
                        HStack { Text(chat.displayName); Spacer(); Text("\(chat.messageCount) messages · \(chat.attachmentCount) files").foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
                if model.selectedConversationIDs.isEmpty { Label("Select at least one conversation, or switch back to All matching conversations.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            } else {
                Label("All \(model.relevantConversations.count) matching conversation\(model.relevantConversations.count == 1 ? "" : "s") will be searched for the content selected above.", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func preflightView(_ report: PreflightReport) -> some View {
        GroupBox("Export review") {
            VStack(alignment: .leading, spacing: 9) {
                Label("\(report.records.count.formatted()) records", systemImage: "message")
                Label("\(report.availableAttachments.formatted()) available attachments · \(ByteCountFormatter.string(fromByteCount: report.estimatedBytes, countStyle: .file))", systemImage: "paperclip")
                if !report.missingItems.isEmpty { Label("\(report.missingItems.count.formatted()) unavailable attachments will be listed in the manifest", systemImage: "icloud.slash").foregroundStyle(.orange) }
                if model.isExporting, let progress = model.progress {
                    ProgressView(value: Double(progress.completedRecords), total: Double(max(progress.totalRecords, 1))) { Text(progress.status) } currentValueLabel: { Text("\(progress.completedRecords) of \(progress.totalRecords)") }
                    Button("Cancel Export", role: .destructive) { model.cancelExport() }
                } else { Button("Choose Folder and Export") { model.chooseDestinationAndExport() }.buttonStyle(.borderedProminent) }
            }.padding(.vertical, 6)
        }
    }

    private func dateSpan(_ snapshot: LibrarySnapshot) -> String {
        guard let first = snapshot.earliest, let last = snapshot.latest else { return "No messages found" }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private func filterCard<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { Image(systemName: icon).font(.title3).foregroundStyle(.blue).frame(width: 24); VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) } }
            content()
        }.padding(16).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }

    private func initials(_ value: String) -> String { value.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    private func contentIcon(_ category: ContentCategory) -> String {
        switch category { case .transcript: "text.bubble"; case .photo: "photo"; case .video: "video"; case .animatedImage: "sparkles.rectangle.stack"; case .audio: "waveform"; case .link: "link"; case .document: "doc"; case .contactCard: "person.crop.rectangle"; case .other: "paperclip" }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox.fill").font(.system(size: 58)).foregroundStyle(.blue)
            VStack(spacing: 5) { Text("MessageVault").font(.largeTitle.bold()); Text("Version \(AppModel.appVersion)").foregroundStyle(.secondary) }
            Text("A private, offline-first exporter for the Messages history stored on your Mac.").multilineTextAlignment(.center).frame(maxWidth: 390)
            Text("Message data never leaves your Mac. MessageVault connects to GitHub only to check for software updates when the app opens or when you request a check.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            HStack { Link("GitHub Repository", destination: UpdateService.repositoryURL); Link("Releases", destination: UpdateService.releasesURL) }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(32).frame(width: 500)
    }
}

struct UpdateResultView: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: UpdatePresentation
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 46)).foregroundStyle(color)
            Text(title).font(.title2.bold())
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack {
                if case .available(let release) = presentation { Link("View Release", destination: release.htmlURL).buttonStyle(.borderedProminent) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(30).frame(width: 520)
    }
    private var title: String { switch presentation { case .available: "An update is available"; case .upToDate: "MessageVault is up to date"; case .failed: "Couldn’t check for updates" } }
    private var message: String { switch presentation { case .available(let release): "\(release.name ?? release.tagName) is available. You’re using version \(AppModel.appVersion).\n\n\(release.body?.prefix(500) ?? "Open the release page to download it.")"; case .upToDate: "You’re using the latest version, \(AppModel.appVersion)."; case .failed(let message): message } }
    private var icon: String { switch presentation { case .available: "arrow.down.circle.fill"; case .upToDate: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill" } }
    private var color: Color { switch presentation { case .available: .blue; case .upToDate: .green; case .failed: .orange } }
}
