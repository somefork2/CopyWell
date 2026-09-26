import AppKit
import Foundation
import SwiftData

@Model
final class ClipboardItem {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var contentType: String = ContentType.text.rawValue
    var contentHash: String = ""

    /// Plaintext body. `nil` for sensitive clips — those live in `encryptedText`.
    var text: String?
    /// ChaCha20-Poly1305 ciphertext for clips detected as secrets.
    var encryptedText: Data?

    /// Full-size image lives on disk (see `ImageStore`); only its file name is stored.
    var imageFileName: String?
    /// Small PNG preview, safe to keep in the database.
    var imageThumbnail: Data?

    /// Original rich text, when the source offered any. Kept so pasting can put
    /// the formatting back; "paste as plain text" is only meaningful because
    /// this exists.
    var richTextData: Data?

    var extractedText: String?
    var url: String?
    var urlTitle: String?
    var sourceApp: String?
    var sourceAppBundleId: String?
    var isSensitive: Bool = false
    var isFavorite: Bool = false
    var isTrashed: Bool = false
    var tags: [String] = []
    var category: String = "uncategorized"
    var detectedLanguage: String?
    var sentiment: Double = 0
    var aiConfidence: Double = 0.5
    var entitiesData: Data?
    var useCount: Int = 0

    /// True pixel dimensions of the stored image, so a row can say what the
    /// image actually is without loading the file.
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// Byte size of the stored image file.
    var imageByteSize: Int = 0

    @Relationship(inverse: \Pinboard.items)
    var pinboard: Pinboard?

    init(
        id: UUID = UUID(),
        contentType: ContentType,
        contentHash: String,
        text: String? = nil,
        imageFileName: String? = nil,
        url: String? = nil,
        sourceApp: String? = nil,
        sourceAppBundleId: String? = nil,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.createdAt = Date()
        self.updatedAt = Date()
        self.contentType = contentType.rawValue
        self.contentHash = contentHash
        self.imageFileName = imageFileName
        self.url = url
        self.sourceApp = sourceApp
        self.sourceAppBundleId = sourceAppBundleId
        self.isSensitive = isSensitive
        self.tags = []
        self.category = "uncategorized"
        setBody(text)
    }

    // MARK: - Body access

    /// Stores `body`, encrypting it when the clip is sensitive.
    func setBody(_ body: String?) {
        guard let body else {
            text = nil
            encryptedText = nil
            return
        }
        if isSensitive {
            text = nil
            encryptedText = SecureStore.seal(body)
        } else {
            text = body
            encryptedText = nil
        }
    }

    /// The clip's text, decrypting on demand. Returns `nil` if the key is gone.
    var body: String? {
        if let text { return text }
        if let encryptedText { return SecureStore.open(encryptedText) }
        return nil
    }

    /// Text safe to render in lists and previews.
    var displayBody: String {
        isSensitive ? "••••••••••••" : (body ?? "")
    }

    /// Promotes an existing clip to sensitive, re-encrypting its body.
    func markSensitive() {
        guard !isSensitive else { return }
        let existing = body
        isSensitive = true
        contentType = ContentType.password.rawValue
        setBody(existing)
    }

    // MARK: - Image access

    var imageData: Data? {
        guard let imageFileName else { return nil }
        return ImageStore.read(fileName: imageFileName)
    }

    var thumbnailImage: NSImage? {
        guard let imageThumbnail else { return nil }
        return NSImage(data: imageThumbnail)
    }

    // MARK: - Derived

    var type: ContentType {
        get { ContentType(rawValue: contentType) ?? .unknown }
        set { contentType = newValue.rawValue }
    }

    var entities: [ExtractedEntity] {
        get {
            guard let entitiesData else { return [] }
            return (try? JSONDecoder().decode([ExtractedEntity].self, from: entitiesData)) ?? []
        }
        set { entitiesData = try? JSONEncoder().encode(newValue) }
    }

    var previewText: String {
        switch type {
        case .image: return imageHeadline
        case .password: return "••••••••••••"
        case .url: return url ?? displayBody
        default: return displayBody
        }
    }

    // MARK: - Image description

    /// What the image is, in one line: the first line of recognised text when
    /// there is any, otherwise its dimensions.
    var imageHeadline: String {
        if let first = recognizedFirstLine { return first }
        if let dimensions = imageDimensionsText { return L("Image · \(dimensions)") }
        return L("Image")
    }

    /// The first line of recognised text, but only when it is worth showing as a
    /// title. OCR on a screenshot with no writing in it happily returns stray
    /// marks like "=" or "|", which say less than the dimensions would.
    var recognizedFirstLine: String? {
        guard let extractedText else { return nil }
        let line = extractedText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { candidate in
                candidate.count >= 3 && candidate.contains { $0.isLetter || $0.isNumber }
            }
        return line
    }

    var imageDimensionsText: String? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth)×\(pixelHeight)"
    }

    var recognizedWordCount: Int {
        guard let extractedText else { return 0 }
        return extractedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The subtitle shown under an image row: dimensions, file size and how much
    /// text was recognised, so the row says what the image is before it is opened.
    var imageSummary: String {
        var parts: [String] = []
        if let dimensions = imageDimensionsText { parts.append(dimensions) }
        if imageByteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(imageByteSize), countStyle: .file))
        }
        let words = recognizedWordCount
        if words > 0 {
            parts.append(L("\(words) words recognised"))
        } else if extractedText == nil {
            parts.append(L("no text recognised"))
        }
        return parts.joined(separator: " · ")
    }

    var displayTitle: String {
        switch type {
        case .url: return urlTitle ?? URL(string: url ?? "")?.host() ?? L("Link")
        case .image: return L("Image")
        case .code: return L("Code Snippet")
        case .password: return L("Protected Item")
        default:
            let preview = displayBody
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(60)
            return preview.isEmpty ? L("Empty") : String(preview)
        }
    }

    /// Everything the search index should consider, built once per change.
    var searchCorpus: String {
        var parts: [String] = []
        if !isSensitive { parts.append(body ?? "") }
        parts.append(url ?? "")
        parts.append(urlTitle ?? "")
        parts.append(extractedText ?? "")
        parts.append(category)
        parts.append(sourceApp ?? "")
        parts.append(contentsOf: tags)
        parts.append(contentsOf: entities.map(\.value))
        return parts.joined(separator: " ").lowercased()
    }

    /// Content to place on the pasteboard for this clip.
    var pasteContent: PasteContent? {
        if type == .image, let data = imageData { return .image(data) }
        guard let body else { return nil }
        if let richTextData, !isSensitive { return .richText(body, richTextData) }
        return .text(body)
    }

    var hasFormatting: Bool { richTextData != nil }
}

extension Date {
    /// Short relative time. Clamped at the low end: a clip captured a moment ago
    /// otherwise renders as "in 0 sec" because capture completes fractionally
    /// after the timestamp is taken.
    var relativeFormatted: String {
        let elapsed = Date().timeIntervalSince(self)
        if elapsed < 10 { return L("now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageBundle.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
