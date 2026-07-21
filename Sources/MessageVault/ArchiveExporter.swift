import AppKit
import CryptoKit
import Foundation

struct ExportProgress: Sendable {
    var completedRecords: Int
    var totalRecords: Int
    var completedBytes: Int64
    var totalBytes: Int64
    var status: String
}

final class ArchiveExporter: @unchecked Sendable {
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func export(report: PreflightReport, filter: ExportFilter, conversations: [ConversationRecord], to destination: URL, progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL {
        let parent = destination.deletingLastPathComponent()
        let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
        let required = report.estimatedBytes + 10_000_000
        guard available >= required else { throw MessageVaultError.insufficientSpace(required: required, available: available) }

        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: destination.path) { throw MessageVaultError.export("A folder already exists at \(destination.path).") }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            for folder in ["media", "documents", "audio"] { try fm.createDirectory(at: temporary.appendingPathComponent(folder), withIntermediateDirectories: false) }
            var records = report.records
            var checksumRows = ["sha256,size,category,timestamp,sender,path"]
            var completedBytes: Int64 = 0
            var completedRecords = 0

            for recordIndex in records.indices {
                try Task.checkCancellation()
                for attachmentIndex in records[recordIndex].attachments.indices {
                    try Task.checkCancellation()
                    var attachment = records[recordIndex].attachments[attachmentIndex]
                    guard attachment.availability == "available", let sourcePath = attachment.sourcePath else { continue }
                    let source = URL(fileURLWithPath: sourcePath)
                    let filename = collisionSafeName(id: attachment.id, source: source, transferName: attachment.transferName)
                    let relative = "\(attachment.category.folder)/\(filename)"
                    let target = temporary.appendingPathComponent(relative)
                    do {
                        try fm.copyItem(at: source, to: target)
                        let hash = try sha256(url: target)
                        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? attachment.totalBytes
                        attachment.relativeExportPath = relative
                        checksumRows.append(csv([hash, String(size), attachment.category.rawValue, ISO8601DateFormatter().string(from: records[recordIndex].timestamp), records[recordIndex].sender, relative]))
                        completedBytes += size
                    } catch {
                        attachment.availability = "copyFailed: \(error.localizedDescription)"
                    }
                    records[recordIndex].attachments[attachmentIndex] = attachment
                    progress(ExportProgress(completedRecords: completedRecords, totalRecords: records.count, completedBytes: completedBytes, totalBytes: report.estimatedBytes, status: "Copying attachments"))
                }
                completedRecords += 1
                progress(ExportProgress(completedRecords: completedRecords, totalRecords: records.count, completedBytes: completedBytes, totalBytes: report.estimatedBytes, status: "Building archive"))
            }

            let selectedConversations = conversations.filter { Set(records.map(\.conversationID)).contains($0.id) }
            let manifest = ArchiveManifest(schemaVersion: 1, createdAt: Date(), appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", filter: filter, conversations: selectedConversations, records: records, missingItems: report.missingItems)
            try encoder.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
            try checksumRows.joined(separator: "\n").data(using: .utf8)!.write(to: temporary.appendingPathComponent("checksums.csv"), options: .atomic)
            try renderHTML(manifest: manifest).data(using: .utf8)!.write(to: temporary.appendingPathComponent("index.html"), options: .atomic)
            try Task.checkCancellation()
            try fm.moveItem(at: temporary, to: destination)
            progress(ExportProgress(completedRecords: records.count, totalRecords: records.count, completedBytes: completedBytes, totalBytes: report.estimatedBytes, status: "Complete"))
            return destination
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private func collisionSafeName(id: Int64, source: URL, transferName: String?) -> String {
        let proposed = (transferName?.isEmpty == false ? transferName! : source.lastPathComponent)
        let safe = proposed.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "_", options: .regularExpression)
        return "\(id)-\(safe.isEmpty ? "attachment" : safe)"
    }

    private func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { () -> Bool in
            let data = try? handle.read(upToCount: 1_048_576)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data); return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func csv(_ values: [String]) -> String { values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }

    private func renderHTML(manifest: ArchiveManifest) -> String {
        let rows = manifest.records.map { record -> String in
            let text = escape(record.text ?? "")
            let links = record.links.map { "<a href=\"\(attribute($0))\">\(escape($0))</a>" }.joined(separator: "<br>")
            let attachments = record.attachments.map { item -> String in
                if let path = item.relativeExportPath {
                    if [.photo, .animatedImage].contains(item.category) { return "<a class=\"attachment\" href=\"\(attribute(path))\"><img loading=\"lazy\" src=\"\(attribute(path))\" alt=\"\(attribute(item.transferName ?? "Image"))\"></a>" }
                    if item.category == .video { return "<video class=\"attachment\" controls preload=\"metadata\" src=\"\(attribute(path))\"></video>" }
                    if item.category == .audio { return "<audio controls preload=\"metadata\" src=\"\(attribute(path))\"></audio>" }
                    return "<a class=\"file\" href=\"\(attribute(path))\">📎 \(escape(item.transferName ?? URL(fileURLWithPath: path).lastPathComponent))</a>"
                }
                return "<span class=\"missing\">Unavailable: \(escape(item.transferName ?? item.originalFilename ?? "attachment"))</span>"
            }.joined(separator: "")
            let reaction = record.associatedMessageGUID == nil ? "" : "<span class=\"meta\">Reaction/edit related to \(escape(record.associatedMessageGUID!))</span>"
            return "<article class=\"message \(record.isFromMe ? "mine" : "theirs")\" data-search=\"\(attribute([record.sender, record.conversationName, record.text ?? "", record.links.joined(separator: " ")].joined(separator: " ").lowercased()))\"><div class=\"meta\">\(escape(record.sender)) · \(escape(record.conversationName)) · \(escape(date(record.timestamp))) · \(escape(record.service))</div><div class=\"bubble\">\(text.replacingOccurrences(of: "\n", with: "<br>"))\(links.isEmpty ? "" : "<div class=\"links\">\(links)</div>")\(attachments)\(reaction)</div></article>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Messages archive</title>
        <style>:root{color-scheme:light dark;font:15px -apple-system,BlinkMacSystemFont,sans-serif}body{margin:0;background:#f5f5f7;color:#1d1d1f}header{position:sticky;top:0;z-index:2;padding:18px max(24px,calc((100% - 900px)/2));background:rgba(245,245,247,.92);backdrop-filter:blur(16px);border-bottom:1px solid #bbb5}h1{margin:0 0 10px;font-size:22px}input{box-sizing:border-box;width:100%;padding:10px 12px;border:1px solid #aaa8;border-radius:10px;background:#fff;color:#111}main{max-width:900px;margin:auto;padding:24px}.message{margin:18px 0;max-width:78%}.message.mine{margin-left:auto}.meta{font-size:11px;color:#6e6e73;margin:0 8px 5px}.bubble{padding:10px 14px;border-radius:18px;background:#e5e5ea;overflow-wrap:anywhere}.mine .bubble{background:#087cff;color:white}.attachment{display:block;max-width:100%;max-height:420px;margin-top:9px;border-radius:12px}.attachment img{display:block;max-width:100%;max-height:420px;border-radius:12px}.file,.links a{display:block;margin-top:8px;color:inherit}.missing{display:block;margin-top:8px;padding:8px;border:1px dashed currentColor;border-radius:8px;opacity:.7}@media(prefers-color-scheme:dark){body{background:#111;color:#eee}header{background:#111d}.bubble{background:#343438}input{background:#222;color:#fff}}</style></head>
        <body><header><h1>Messages archive</h1><input id="q" type="search" placeholder="Search people, conversations, and messages" aria-label="Search archive"></header><main id="messages">\(rows)</main>
        <script>const q=document.getElementById('q');q.addEventListener('input',()=>{const v=q.value.toLowerCase();document.querySelectorAll('.message').forEach(e=>e.hidden=!e.dataset.search.includes(v))})</script></body></html>
        """
    }

    private func date(_ value: Date) -> String { DateFormatter.localizedString(from: value, dateStyle: .medium, timeStyle: .short) }
    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    private func attribute(_ value: String) -> String { escape(value).replacingOccurrences(of: "'", with: "&#39;") }
}
