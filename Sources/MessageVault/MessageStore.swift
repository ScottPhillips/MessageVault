import Foundation

final class MessageStore {
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    private let databaseURL: URL
    init(databaseURL: URL = MessageStore.defaultDatabaseURL) { self.databaseURL = databaseURL }

    var hasFullDiskAccess: Bool {
        do {
            let db = try SQLiteDatabase(url: databaseURL)
            try db.query("SELECT 1") { _ in }
            return true
        } catch { return false }
    }

    func scan(contactMatches: [String: ContactMatch] = [:]) throws -> LibrarySnapshot {
        guard hasFullDiskAccess else { throw MessageVaultError.fullDiskAccessRequired }
        let db = try SQLiteDatabase(url: databaseURL)
        try validate(db)
        try db.beginSnapshot(); defer { db.endSnapshot() }

        var handles: [Int64: String] = [:]
        try db.query("SELECT ROWID, id FROM handle") { handles[$0.int64(0)] = $0.string(1) ?? "Unknown" }
        let conversations = try loadConversations(db: db, handles: handles)
        var messageCounts: [Int64: Int] = [:], attachmentCounts: [Int64: Int] = [:], latestDates: [Int64: Date] = [:]
        try db.query("""
            SELECT chj.handle_id, COUNT(DISTINCT cmj.message_id), COUNT(DISTINCT maj.attachment_id), MAX(m.date)
            FROM chat_handle_join chj
            JOIN chat_message_join cmj ON cmj.chat_id = chj.chat_id
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            GROUP BY chj.handle_id
            """) {
            messageCounts[$0.int64(0)] = $0.int(1)
            attachmentCounts[$0.int64(0)] = $0.int(2)
            latestDates[$0.int64(0)] = Self.appleDate($0.int64(3))
        }

        var grouped: [String: PersonRecord] = [:]
        for (rowID, raw) in handles {
            let normalized = HandleNormalizer.normalize(raw)
            let match = contactMatches[normalized]
            let key = match?.identifier ?? normalized
            var person = grouped[key] ?? PersonRecord(id: key, displayName: match?.name ?? raw, handles: [], handleRowIDs: [], contactIdentifier: match?.identifier, messageCount: 0, attachmentCount: 0, latestMessageDate: nil)
            if !person.handles.contains(raw) { person.handles.append(raw) }
            person.handleRowIDs.append(rowID)
            person.messageCount += messageCounts[rowID, default: 0]
            person.attachmentCount += attachmentCounts[rowID, default: 0]
            if let latest = latestDates[rowID], person.latestMessageDate == nil || latest > person.latestMessageDate! { person.latestMessageDate = latest }
            grouped[key] = person
        }

        var earliest: Date?, latest: Date?, total = 0
        try db.query("SELECT MIN(date), MAX(date), COUNT(*) FROM message") {
            earliest = Self.appleDate($0.int64(0)); latest = Self.appleDate($0.int64(1)); total = $0.int(2)
        }
        var attachmentTotal = 0
        try db.query("SELECT COUNT(*) FROM attachment") { attachmentTotal = $0.int(0) }
        return LibrarySnapshot(people: grouped.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }, conversations: conversations, earliest: earliest, latest: latest, messageCount: total, attachmentCount: attachmentTotal)
    }

    func preflight(filter: ExportFilter) throws -> PreflightReport {
        guard hasFullDiskAccess else { throw MessageVaultError.fullDiskAccessRequired }
        let db = try SQLiteDatabase(url: databaseURL)
        try validate(db)
        try db.beginSnapshot(); defer { db.endSnapshot() }
        var handles: [Int64: String] = [:]
        try db.query("SELECT ROWID, id FROM handle") { handles[$0.int64(0)] = $0.string(1) ?? "Unknown" }
        let conversations = try loadConversations(db: db, handles: handles)
        let candidateChats: Set<Int64> = Set(conversations.filter { chat in
            let contains = !Set(chat.participantHandleIDs).isDisjoint(with: filter.person.handleRowIDs)
            let scopeOK = filter.scope != .directOnly || chat.participantHandleIDs.count == 1
            let selectedOK = filter.conversationIDs.isEmpty || filter.conversationIDs.contains(chat.id)
            return contains && scopeOK && selectedOK
        }.map(\.id))
        if candidateChats.isEmpty { throw MessageVaultError.noRecords }

        let messageColumns = try db.columns(in: "message")
        let attributed = messageColumns.contains("attributedBody") ? "m.attributedBody" : "NULL"
        let associatedGUID = messageColumns.contains("associated_message_guid") ? "m.associated_message_guid" : "NULL"
        let associatedType = messageColumns.contains("associated_message_type") ? "m.associated_message_type" : "NULL"
        let threadGUID = messageColumns.contains("thread_originator_guid") ? "m.thread_originator_guid" : "NULL"
        let placeholders = candidateChats.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT m.ROWID, COALESCE(m.guid, CAST(m.ROWID AS TEXT)), m.date, m.handle_id, m.is_from_me,
               COALESCE(m.service, ''), m.text, \(attributed), cmj.chat_id, \(associatedGUID), \(associatedType), \(threadGUID)
        FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id IN (\(placeholders)) ORDER BY m.date, m.ROWID
        """
        var records: [ExportRecord] = []
        let chatMap = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        try db.query(sql, bindings: candidateChats.sorted().map(SQLiteValue.integer)) { row in
            let date = Self.appleDate(row.int64(2))
            let senderID = row.int64(3)
            let fromMe = row.bool(4)
            guard Self.matchesDate(date, filter: filter), Self.matchesDirection(fromMe, filter: filter.direction) else { return }
            if filter.scope == .onlyTheirMessages && !filter.person.handleRowIDs.contains(senderID) { return }
            let chatID = row.int64(8)
            let plain = row.string(6) ?? Self.decodeAttributedBody(row.data(7))
            let links = Self.extractLinks(from: plain)
            let record = ExportRecord(id: row.int64(0), guid: row.string(1) ?? "", timestamp: date, sender: fromMe ? "Me" : (handles[senderID] ?? "Unknown"), senderHandleID: fromMe ? nil : senderID, isFromMe: fromMe, service: row.string(5) ?? "", conversationID: chatID, conversationName: chatMap[chatID]?.displayName ?? "Conversation", text: plain, associatedMessageGUID: row.string(9), associatedMessageType: row.string(10).flatMap(Int.init) ?? (row.int(10) == 0 ? nil : row.int(10)), threadOriginatorGUID: row.string(11), links: links, attachments: [])
            records.append(record)
        }

        let indexByMessage = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        if !records.isEmpty {
            let ids = records.map(\.id)
            for chunk in stride(from: 0, to: ids.count, by: 800) {
                let batch = Array(ids[chunk..<min(chunk + 800, ids.count)])
                let marks = batch.map { _ in "?" }.joined(separator: ",")
                let attachmentSQL = """
                SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.uti, a.transfer_name,
                       COALESCE(a.total_bytes, 0), COALESCE(a.is_outgoing, 0)
                FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN (\(marks))
                """
                try db.query(attachmentSQL, bindings: batch.map(SQLiteValue.integer)) { row in
                    guard let recordIndex = indexByMessage[row.int64(0)] else { return }
                    let rawPath = row.string(2)
                    let resolved = Self.resolveAttachmentPath(rawPath)
                    let category = ContentCategory.classify(mime: row.string(3), uti: row.string(4), filename: row.string(5) ?? rawPath)
                    let exists = resolved.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
                    records[recordIndex].attachments.append(AttachmentRecord(id: row.int64(1), originalFilename: rawPath, sourcePath: resolved, mimeType: row.string(3), uti: row.string(4), transferName: row.string(5), totalBytes: row.int64(6), isOutgoing: row.bool(7), category: category, relativeExportPath: nil, availability: exists ? "available" : "missing"))
                }
            }
        }

        records = records.compactMap { record in
            var copy = record
            copy.attachments = copy.attachments.filter { filter.categories.contains($0.category) }
            if !filter.categories.contains(.link) { copy.links = [] }
            let includeTranscript = filter.categories.contains(.transcript) && (copy.text?.isEmpty == false)
            return includeTranscript || !copy.links.isEmpty || !copy.attachments.isEmpty ? copy : nil
        }
        guard !records.isEmpty else { throw MessageVaultError.noRecords }
        let attachments = records.flatMap(\.attachments)
        let missing = attachments.filter { $0.availability != "available" }.map {
            MissingItem(id: "attachment-\($0.id)", attachmentID: $0.id, originalPath: $0.originalFilename, reason: "The attachment is not downloaded or no longer exists on this Mac.")
        }
        return PreflightReport(records: records, availableAttachments: attachments.count - missing.count, missingItems: missing, unsupportedRecords: records.filter { $0.text == nil && $0.attachments.isEmpty }.count, estimatedBytes: attachments.filter { $0.availability == "available" }.reduce(0) { $0 + max($1.totalBytes, 0) })
    }

    private func validate(_ db: SQLiteDatabase) throws {
        let required: [String: Set<String>] = [
            "message": ["ROWID", "date", "is_from_me"], "handle": ["ROWID", "id"],
            "chat": ["ROWID", "chat_identifier"], "attachment": ["ROWID", "filename"],
            "chat_message_join": ["chat_id", "message_id"], "chat_handle_join": ["chat_id", "handle_id"],
            "message_attachment_join": ["message_id", "attachment_id"]
        ]
        var missing: [String] = []
        for (table, columns) in required {
            let available = try db.columns(in: table)
            if available.isEmpty { missing.append(table); continue }
            for column in columns where !available.contains(column) { missing.append("\(table).\(column)") }
        }
        if !missing.isEmpty { throw MessageVaultError.unsupportedSchema(missing.sorted()) }
    }

    private func loadConversations(db: SQLiteDatabase, handles: [Int64: String]) throws -> [ConversationRecord] {
        var participants: [Int64: [Int64]] = [:]
        try db.query("SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id") { participants[$0.int64(0), default: []].append($0.int64(1)) }
        var counts: [Int64: (Int, Int)] = [:]
        try db.query("SELECT cmj.chat_id, COUNT(DISTINCT cmj.message_id), COUNT(DISTINCT maj.attachment_id) FROM chat_message_join cmj LEFT JOIN message_attachment_join maj ON maj.message_id = cmj.message_id GROUP BY cmj.chat_id") { counts[$0.int64(0)] = ($0.int(1), $0.int(2)) }
        var result: [ConversationRecord] = []
        try db.query("SELECT ROWID, COALESCE(chat_identifier, ''), COALESCE(display_name, '') FROM chat") { row in
            let id = row.int64(0), ids = participants[id, default: []], rawName = row.string(2) ?? ""
            let values = ids.compactMap { handles[$0] }
            let name = rawName.isEmpty ? (values.isEmpty ? (row.string(1) ?? "Conversation") : values.joined(separator: ", ")) : rawName
            let count = counts[id] ?? (0, 0)
            result.append(ConversationRecord(id: id, identifier: row.string(1) ?? "", displayName: name, participantHandleIDs: ids, participantHandles: values, messageCount: count.0, attachmentCount: count.1))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func appleDate(_ raw: Int64) -> Date {
        let seconds = abs(raw) > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
    private static func matchesDate(_ date: Date, filter: ExportFilter) -> Bool { (filter.startDate == nil || date >= filter.startDate!) && (filter.endDate == nil || date <= filter.endDate!) }
    private static func matchesDirection(_ fromMe: Bool, filter: DirectionFilter) -> Bool { filter == .all || (filter == .outgoing && fromMe) || (filter == .incoming && !fromMe) }
    private static func decodeAttributedBody(_ data: Data?) -> String? {
        guard let data else { return nil }
        if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
            if let attributed = object as? NSAttributedString { return attributed.string }
            if let string = object as? NSString { return string as String }
        }
        return nil
    }
    private static func extractLinks(from text: String?) -> [String] {
        guard let text, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url?.absoluteString)
    }
    private static func resolveAttachmentPath(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        value = NSString(string: value).expandingTildeInPath
        if value.hasPrefix("/") { return value }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(value).path
    }
}
