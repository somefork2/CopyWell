import CloudKit
import Foundation

/// A clip flattened into something that can cross actor boundaries.
struct CloudClip: Sendable {
    var contentHash: String
    var contentType: String
    var text: String?
    var url: String?
    var urlTitle: String?
    var sourceApp: String?
    var category: String
    var tags: [String]
    var isFavorite: Bool
    var createdAt: Date

    init?(_ item: ClipboardItem) {
        // Sensitive clips stay on the device that captured them. So do images:
        // the record carries no picture, and another Mac received an empty
        // "Image" clip that pasted nothing.
        guard !item.isSensitive, item.type != .image else { return nil }
        contentHash = item.contentHash
        contentType = item.contentType
        text = item.body
        url = item.url
        urlTitle = item.urlTitle
        sourceApp = item.sourceApp
        category = item.category
        tags = item.tags
        isFavorite = item.isFavorite
        createdAt = item.createdAt
    }

    init(record: CKRecord) throws {
        guard let hash = record["contentHash"] as? String,
              let type = record["contentType"] as? String else {
            throw SyncError.malformedRecord
        }
        contentHash = hash
        contentType = type
        text = record["text"] as? String
        url = record["url"] as? String
        urlTitle = record["urlTitle"] as? String
        sourceApp = record["sourceApp"] as? String
        category = record["category"] as? String ?? "uncategorized"
        tags = (record["tags"] as? [String]) ?? []
        isFavorite = (record["isFavorite"] as? Int).map { $0 == 1 } ?? false
        createdAt = record["createdAt"] as? Date ?? Date()
    }

    /// Converts back into the shape the store inserts.
    var captured: CapturedClip {
        CapturedClip(
            contentType: ContentType(rawValue: contentType) ?? .text,
            contentHash: contentHash,
            text: text,
            url: url,
            urlTitle: urlTitle,
            imageFileName: nil,
            imageThumbnail: nil,
            extractedText: nil,
            sourceApp: sourceApp,
            sourceAppBundleId: nil,
            isSensitive: false,
            category: category,
            tags: tags,
            detectedLanguage: nil,
            sentiment: 0,
            confidence: 0.5,
            entities: [],
            createdAt: createdAt,
            isFavorite: isFavorite
        )
    }
}

enum SyncError: Error {
    case unavailable
    case malformedRecord
}

/// What one exchange with iCloud produced.
struct SyncChanges: Sendable {
    var incoming: [CapturedClip] = []
    /// Clips deleted on another device.
    var removedHashes: [String] = []
}

enum SyncResult: Sendable {
    case success(SyncChanges)
    case failure(String)
}

/// Sync through a custom record zone in the user's private database.
///
/// A custom zone reports its own changes against a server token, so there are no
/// queries — and therefore no record types, fields or indexes to create by hand
/// in the CloudKit console before the feature works. The zone and its schema are
/// created on first use. It is also how deletions reach other devices at all: a
/// query-based sync can only see what still exists.
actor CloudKitSyncManager {
    static let shared = CloudKitSyncManager()

    private let recordType = "ClipboardItemRecord"
    private let zoneName = "CopyWellHistory"
    private let tokenKey = "sync_server_change_token"

    private var container: CKContainer?
    private var database: CKDatabase?
    private var zoneIsReady = false

    private init() {}

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Resolves the container lazily. Touching CloudKit without the iCloud
    /// entitlement traps at runtime, so we only do it on demand and stay `nil`
    /// when the build is not configured for sync.
    private func resolveDatabase() -> CKDatabase? {
        if let database { return database }
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let container = CKContainer(identifier: "iCloud.\(bundleID)")
        self.container = container
        let database = container.privateCloudDatabase
        self.database = database
        return database
    }

    func checkAccountStatus() async -> Bool {
        _ = resolveDatabase()
        guard let container else { return false }
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    // MARK: - Sync

    /// Pushes local clips and deletions, then pulls whatever other devices have
    /// changed since the last token.
    func sync(localItems: [CloudClip?], deletedHashes: [String] = []) async -> SyncResult {
        let local = localItems.compactMap { $0 }
        guard let database = resolveDatabase() else {
            return .failure(L("iCloud sync is not configured for this build."))
        }
        guard await checkAccountStatus() else {
            return .failure(L("Sign in to iCloud in System Settings to use sync."))
        }

        do {
            try await ensureZone(in: database)

            let deletions = Set(deletedHashes)
            if !deletions.isEmpty {
                try await delete(Array(deletions), from: database)
            }

            let toPush = local.filter { !deletions.contains($0.contentHash) }
            if !toPush.isEmpty {
                try await push(toPush, to: database)
            }

            let changes = try await pull(from: database, skipping: deletions)
            return .success(changes)
        } catch let error as CKError {
            return .failure(describe(error))
        } catch {
            return .failure(L("Sync failed: \(error.localizedDescription)"))
        }
    }

    private func describe(_ error: CKError) -> String {
        switch error.code {
        case .networkUnavailable, .networkFailure:
            return L("No network connection. Sync will resume when you are back online.")
        case .notAuthenticated:
            return L("Sign in to iCloud in System Settings to use sync.")
        case .quotaExceeded:
            return L("Your iCloud storage is full.")
        case .permissionFailure:
            return L("CopyWell does not have permission to use iCloud on this Mac.")
        case .serviceUnavailable, .requestRateLimited:
            return L("iCloud is busy. CopyWell will try again shortly.")
        default:
            return L("Sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Zone

    /// Creates the zone if it is missing. Saving a record also creates the record
    /// type and its fields, so nothing has to be defined in the console first.
    private func ensureZone(in database: CKDatabase) async throws {
        guard !zoneIsReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        zoneIsReady = true
    }

    // MARK: - Push

    private func push(_ clips: [CloudClip], to database: CKDatabase) async throws {
        let records = clips.map { clip -> CKRecord in
            // A record name derived from the content means the same clip maps to
            // one record on every device instead of duplicating.
            let id = CKRecord.ID(recordName: ContentHasher.recordName(for: clip.contentHash), zoneID: zoneID)
            let record = CKRecord(recordType: recordType, recordID: id)
            record["contentHash"] = clip.contentHash as CKRecordValue
            record["contentType"] = clip.contentType as CKRecordValue
            record["text"] = (clip.text ?? "") as CKRecordValue
            record["url"] = (clip.url ?? "") as CKRecordValue
            record["urlTitle"] = (clip.urlTitle ?? "") as CKRecordValue
            record["sourceApp"] = (clip.sourceApp ?? "") as CKRecordValue
            record["category"] = clip.category as CKRecordValue
            record["tags"] = clip.tags as CKRecordValue
            record["isFavorite"] = (clip.isFavorite ? 1 : 0) as CKRecordValue
            record["createdAt"] = clip.createdAt as CKRecordValue
            return record
        }

        for chunk in records.chunked(by: 200) {
            _ = try await database.modifyRecords(saving: chunk, deleting: [], savePolicy: .changedKeys)
        }
    }

    // MARK: - Pull

    private func pull(from database: CKDatabase, skipping deletions: Set<String>) async throws -> SyncChanges {
        var changes = SyncChanges()
        var token = loadToken()
        var moreComing = true

        while moreComing {
            let result: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )

            do {
                result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired {
                // The server no longer knows where we were; start over.
                saveToken(nil)
                token = nil
                continue
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // The zone was removed on another device or by the user.
                saveToken(nil)
                zoneIsReady = false
                try await ensureZone(in: database)
                return changes
            }

            for (_, modification) in result.modificationResultsByID {
                guard case .success(let change) = modification,
                      let clip = try? CloudClip(record: change.record),
                      !deletions.contains(clip.contentHash) else { continue }
                changes.incoming.append(clip.captured)
            }

            for deletion in result.deletions {
                changes.removedHashes.append(contentHash(fromRecordName: deletion.recordID.recordName))
            }

            token = result.changeToken
            moreComing = result.moreComing
        }

        saveToken(token)
        return changes
    }

    /// Record names are the leading part of the content hash, which is what the
    /// local store keys on too.
    private nonisolated func contentHash(fromRecordName name: String) -> String { name }

    // MARK: - Delete

    func delete(contentHash: String) async throws {
        guard let database = resolveDatabase() else { throw SyncError.unavailable }
        try await delete([contentHash], from: database)
    }

    private func delete(_ contentHashes: [String], from database: CKDatabase) async throws {
        guard !contentHashes.isEmpty else { return }
        let ids = contentHashes.map {
            CKRecord.ID(recordName: ContentHasher.recordName(for: $0), zoneID: zoneID)
        }
        for chunk in ids.chunked(by: 200) {
            _ = try await database.modifyRecords(saving: [], deleting: chunk)
        }
    }

    // MARK: - Change token

    private func loadToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveToken(_ token: CKServerChangeToken?) {
        guard let token else {
            UserDefaults.standard.removeObject(forKey: tokenKey)
            return
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(token, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        UserDefaults.standard.set(archiver.encodedData, forKey: tokenKey)
    }

    /// Forgets where sync got to, so the next exchange pulls everything again.
    func resetChangeToken() {
        saveToken(nil)
        zoneIsReady = false
    }
}

private extension Array {
    /// CloudKit rejects oversized modify operations.
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
