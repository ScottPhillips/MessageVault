import Foundation
import UniformTypeIdentifiers

enum PersonScope: String, Codable, CaseIterable, Identifiable {
    case directOnly = "Direct only"
    case allSharedHistory = "All shared history"
    case onlyTheirMessages = "Only their messages"
    var id: String { rawValue }
}

enum DirectionFilter: String, Codable, CaseIterable, Identifiable {
    case all = "Both directions"
    case incoming = "Incoming only"
    case outgoing = "Outgoing only"
    var id: String { rawValue }
}

enum ContentCategory: String, Codable, CaseIterable, Identifiable {
    case transcript, photo, video, animatedImage, audio, link, document, contactCard, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .animatedImage: "Animated images"
        case .contactCard: "Contact cards"
        default: rawValue.capitalized
        }
    }
    var folder: String {
        switch self {
        case .photo, .video, .animatedImage: "media"
        case .audio: "audio"
        default: "documents"
        }
    }
}

struct PersonRecord: Identifiable, Hashable, Codable {
    let id: String
    var displayName: String
    var handles: [String]
    var handleRowIDs: [Int64]
    var contactIdentifier: String?
    var messageCount: Int
    var attachmentCount: Int
    var latestMessageDate: Date?
}

struct ConversationRecord: Identifiable, Hashable, Codable {
    let id: Int64
    let identifier: String
    let displayName: String
    let participantHandleIDs: [Int64]
    let participantHandles: [String]
    let messageCount: Int
    let attachmentCount: Int
}

struct LibrarySnapshot: Sendable {
    var people: [PersonRecord]
    var conversations: [ConversationRecord]
    var earliest: Date?
    var latest: Date?
    var messageCount: Int
    var attachmentCount: Int
}

struct ExportFilter: Codable, Sendable {
    var person: PersonRecord
    var scope: PersonScope
    var direction: DirectionFilter
    var startDate: Date?
    var endDate: Date?
    var conversationIDs: Set<Int64>
    var categories: Set<ContentCategory>
}

struct AttachmentRecord: Identifiable, Codable, Sendable {
    let id: Int64
    let originalFilename: String?
    let sourcePath: String?
    let mimeType: String?
    let uti: String?
    let transferName: String?
    let totalBytes: Int64
    let isOutgoing: Bool
    var category: ContentCategory
    var relativeExportPath: String?
    var availability: String
}

struct ExportRecord: Identifiable, Codable, Sendable {
    let id: Int64
    let guid: String
    let timestamp: Date
    let sender: String
    let senderHandleID: Int64?
    let isFromMe: Bool
    let service: String
    let conversationID: Int64
    let conversationName: String
    let text: String?
    let associatedMessageGUID: String?
    let associatedMessageType: Int?
    let threadOriginatorGUID: String?
    var links: [String]
    var attachments: [AttachmentRecord]
}

struct MissingItem: Identifiable, Codable, Sendable {
    let id: String
    let attachmentID: Int64
    let originalPath: String?
    let reason: String
}

struct PreflightReport: Sendable {
    var records: [ExportRecord]
    var availableAttachments: Int
    var missingItems: [MissingItem]
    var unsupportedRecords: Int
    var estimatedBytes: Int64
}

struct ArchiveManifest: Codable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let filter: ExportFilter
    let conversations: [ConversationRecord]
    let records: [ExportRecord]
    let missingItems: [MissingItem]
}

enum MessageVaultError: LocalizedError {
    case fullDiskAccessRequired
    case unsupportedSchema([String])
    case database(String)
    case noPersonSelected
    case noRecords
    case insufficientSpace(required: Int64, available: Int64)
    case export(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired: "Full Disk Access is required to read the local Messages library."
        case .unsupportedSchema(let names): "This Messages database format is not supported. Missing: \(names.joined(separator: ", "))."
        case .database(let message): "Messages database error: \(message)"
        case .noPersonSelected: "Choose a person to export."
        case .noRecords: "No locally available messages match these filters."
        case .insufficientSpace(let required, let available): "The export needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        case .export(let message): "Export failed: \(message)"
        }
    }
}

extension ContentCategory {
    static func classify(mime: String?, uti: String?, filename: String?) -> ContentCategory {
        let lowerMime = mime?.lowercased() ?? ""
        let ext = (filename as NSString?)?.pathExtension.lowercased() ?? ""
        let type = uti.flatMap(UTType.init) ?? UTType(filenameExtension: ext)
        if lowerMime == "image/gif" || ext == "gif" { return .animatedImage }
        if lowerMime.hasPrefix("image/") || type?.conforms(to: .image) == true { return .photo }
        if lowerMime.hasPrefix("video/") || type?.conforms(to: .movie) == true { return .video }
        if lowerMime.hasPrefix("audio/") || type?.conforms(to: .audio) == true { return .audio }
        if type?.conforms(to: .vCard) == true || ext == "vcf" { return .contactCard }
        if lowerMime == "text/x-vlocation" || ext == "webloc" { return .link }
        if type?.conforms(to: .content) == true { return .document }
        return .other
    }
}
