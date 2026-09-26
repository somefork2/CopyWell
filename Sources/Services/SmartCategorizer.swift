import NaturalLanguage
import Foundation

// MARK: - Categorisation result

struct CategorizationResult: Sendable {
    let category: ContentCategory
    let language: String?
    let confidence: Double
    let entities: [ExtractedEntity]
    let sentiment: Double  // -1.0 negative ... 0.0 neutral ... +1.0 positive
    let tags: [String]
    let suggestedTitle: String
    let isSensitive: Bool
}

struct ExtractedEntity: Identifiable, Codable, Sendable, Hashable {
    var id = UUID()
    let type: EntityType
    let value: String
    let range: NSRange?
}

enum EntityType: String, Codable, CaseIterable, Sendable {
    case email
    case phoneNumber
    case url
    case personalName
    case organizationName
    case placeName
    case date
    case monetaryAmount
    case codeSnippet

    var displayName: String {
        switch self {
        case .email: return L("Email")
        case .phoneNumber: return L("Phone")
        case .url: return "URL"
        case .personalName: return L("Name")
        case .organizationName: return L("Organization")
        case .placeName: return L("Place")
        case .date: return L("Date")
        case .monetaryAmount: return L("Money")
        case .codeSnippet: return L("Code")
        }
    }

    var icon: String {
        switch self {
        case .email: return "envelope.fill"
        case .phoneNumber: return "phone.fill"
        case .url: return "link"
        case .personalName: return "person.fill"
        case .organizationName: return "building.2.fill"
        case .placeName: return "mappin.circle.fill"
        case .date: return "calendar"
        case .monetaryAmount: return "dollarsign.circle.fill"
        case .codeSnippet: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Smart Categorizer (NaturalLanguage + Apple Intelligence)

actor SmartCategorizer {

    static let shared = SmartCategorizer()

    // Cache for language detection
    private let languageRecognizer = NLLanguageRecognizer()
    private var cachedModels: [String: NLModel] = [:]

    // MARK: - Categorising

    func categorize(_ text: String) async -> CategorizationResult {
        // 1. Language
        let language = detectLanguage(text)

        // 2. Named entities
        let entities = extractEntities(from: text)

        // 3. Content category
        let category = classifyContent(text, entities: entities)

        // 4. Sentiment
        let sentiment = analyzeSentiment(text)

        // 5. Tags
        let tags = extractTags(from: text, entities: entities)

        // 6. Sensitivity
        let isSensitive = checkSensitivity(text, entities: entities)

        // 7. Suggested title
        let title = suggestTitle(text, category: category, entities: entities)

        // 8. Confidence
        let confidence = calculateConfidence(entities: entities, category: category)

        return CategorizationResult(
            category: category, language: language, confidence: confidence,
            entities: entities, sentiment: sentiment, tags: tags,
            suggestedTitle: title, isSensitive: isSensitive
        )
    }

    // MARK: - Language

    private func detectLanguage(_ text: String) -> String? {
        languageRecognizer.reset()
        languageRecognizer.processString(text)
        guard let lang = languageRecognizer.dominantLanguage else { return nil }
        return lang.rawValue
    }

    // MARK: - Named entities

    private func extractEntities(from text: String) -> [ExtractedEntity] {
        var entities: [ExtractedEntity] = []
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard let tag else { return true }

            let entityValue = String(text[range])
            let nsRange = NSRange(range, in: text)

            switch tag {
            case .personalName:
                entities.append(ExtractedEntity(type: .personalName, value: entityValue, range: nsRange))
            case .organizationName:
                entities.append(ExtractedEntity(type: .organizationName, value: entityValue, range: nsRange))
            case .placeName:
                entities.append(ExtractedEntity(type: .placeName, value: entityValue, range: nsRange))
            default:
                break
            }
            return true
        }

        // Plus regex for email, phone, URL and dates
        entities.append(contentsOf: extractRegexEntities(from: text))

        return entities
    }

    private func extractRegexEntities(from text: String) -> [ExtractedEntity] {
        var entities: [ExtractedEntity] = []

        // Email
        let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        if let regex = try? NSRegularExpression(pattern: emailPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    entities.append(ExtractedEntity(type: .email, value: String(text[range]), range: match.range))
                }
            }
        }

        // Phone
        let phonePattern = #"[\+]?[(]?[0-9]{1,4}[)]?[-\s\.]?[0-9]{1,4}[-\s\.]?[0-9]{1,9}"#
        if let regex = try? NSRegularExpression(pattern: phonePattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let phone = String(text[range]).trimmingCharacters(in: .whitespaces)
                    if phone.count >= 7 {
                        entities.append(ExtractedEntity(type: .phoneNumber, value: phone, range: match.range))
                    }
                }
            }
        }

        // URL
        let urlPattern = #"https?://[^\s]+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    entities.append(ExtractedEntity(type: .url, value: String(text[range]), range: match.range))
                }
            }
        }

        // Monetary amounts
        let moneyPattern = #"[\$€£¥][\d,]+\.?\d*"# 
        if let regex = try? NSRegularExpression(pattern: moneyPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let range = Range(match.range, in: text) {
                    entities.append(ExtractedEntity(type: .monetaryAmount, value: String(text[range]), range: match.range))
                }
            }
        }

        return entities
    }

    // MARK: - Content classification

    private func classifyContent(_ text: String, entities: [ExtractedEntity]) -> ContentCategory {
        // Code
        if looksLikeCode(text) { return .code }

        // Links
        if entities.contains(where: { $0.type == .url }) { return .links }

        // Contacts
        let hasEmail = entities.contains(where: { $0.type == .email })
        let hasPhone = entities.contains(where: { $0.type == .phoneNumber })
        let hasName = entities.contains(where: { $0.type == .personalName })
        if hasEmail || hasPhone || hasName { return .contacts }

        // Addresses
        if entities.contains(where: { $0.type == .placeName }) { return .addresses }

        // Long text reads as a note
        if text.count > 300 { return .notes }

        return .text
    }

    private func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeIndicators = [
            "func ", "var ", "let ", "if ", "else ", "for ", "while ",
            "class ", "struct ", "enum ", "protocol ", "import ",
            "return ", "print(", "console.log", "def ", "self.",
            "<div", "<span", "<html", "<?php", "#include",
            "=>", "->", "&&", "||", "!=", "===", "!=="
        ]
        for indicator in codeIndicators {
            if trimmed.lowercased().contains(indicator.lowercased()) { return true }
        }

        // Balanced brackets
        let openBraces = text.filter { $0 == "{" }.count
        let closeBraces = text.filter { $0 == "}" }.count
        if openBraces > 0 && openBraces == closeBraces { return true }

        let openParens = text.filter { $0 == "(" }.count
        let closeParens = text.filter { $0 == ")" }.count
        if openParens > 2 && openParens == closeParens { return true }

        return false
    }

    // MARK: - Sentiment Analysis

    private func analyzeSentiment(_ text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text

        guard let tag = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0 else {
            return 0.0
        }
        return Double(tag.rawValue) ?? 0.0
    }

    // MARK: - Tag Extraction

    private func extractTags(from text: String, entities: [ExtractedEntity]) -> [String] {
        var tags: [String] = []
        let lowercased = text.lowercased()

        // Tags from the content
        if lowercased.contains("todo") || lowercased.contains("задача") || lowercased.contains("task") { tags.append("todo") }
        if lowercased.contains("meeting") || lowercased.contains("встреча") || lowercased.contains("sync") { tags.append("meeting") }
        if lowercased.contains("deadline") || lowercased.contains("дедлайн") || lowercased.contains("крайний срок") { tags.append("deadline") }
        if lowercased.contains("password") || lowercased.contains("пароль") || lowercased.contains("token") { tags.append("sensitive") }
        if lowercased.contains("bug") || lowercased.contains("fix") || lowercased.contains("error") || lowercased.contains("ошибка") { tags.append("bug") }
        if lowercased.contains("idea") || lowercased.contains("идея") || lowercased.contains(" thoughts") { tags.append("idea") }
        if lowercased.contains("link") || lowercased.contains("ссылка") || lowercased.contains("check") { tags.append("link") }
        if lowercased.contains("address") || lowercased.contains("адрес") || lowercased.contains("улица") { tags.append("address") }

        // Tags from the entities
        if entities.contains(where: { $0.type == .email }) { tags.append("email") }
        if entities.contains(where: { $0.type == .phoneNumber }) { tags.append("phone") }
        if entities.contains(where: { $0.type == .organizationName }) { tags.append("company") }

        // Drop duplicates
        return Array(Set(tags)).sorted()
    }

    // MARK: - Sensitivity Check

    /// True when the text looks like a credential, not merely mentions one.
    ///
    /// This used to match plain substrings — "auth", "token", "pwd", "ssn" —
    /// and any short text with an email address in it. Sensitive clips are not
    /// recorded at all while "skip passwords" is on, which is the default, so
    /// a copied email address, an `/oauth/` link, an `/author/` page or JSX
    /// with `className` in it all vanished without a trace. The patterns below
    /// look for the shape of a secret instead: a labelled value, a known token
    /// format, a private key, a card number that passes the Luhn check.
    nonisolated static func looksLikeSecret(_ text: String) -> Bool {
        let patterns = [
            // "password: hunter2", "api_key=…", "пароль: …"
            #"(?i)\b(password|passwd|pwd|passcode|pin code|secret|client[_-]?secret|api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|auth[_-]?token|access[_-]?token|refresh[_-]?token|token|пароль|парол[ья]|kennwort|mot de passe|contraseña|senha|密码|パスワード|비밀번호)\s*[:=：]\s*\S+"#,
            #"(?i)\bbearer\s+[A-Za-z0-9\-._~+/]{16,}=*"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#,
            #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
            #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
            #"\b[rs]k_live_[A-Za-z0-9]{16,}\b"#,
            #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}\b"#,
            #"\bAIza[0-9A-Za-z_-]{35}\b"#,
            #"(?i)\b(cvv|cvc|cvv2)\s*[:=]?\s*\d{3,4}\b"#,
            #"\b\d{3}-\d{2}-\d{4}\b"#,
        ]
        for pattern in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return containsCardNumber(text)
    }

    /// 13–19 digits, optionally grouped by spaces or dashes, passing Luhn —
    /// so order numbers and phone numbers do not count.
    nonisolated private static func containsCardNumber(_ text: String) -> Bool {
        let pattern = #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            let digits = text[range].compactMap(\.wholeNumberValue)
            if (13...19).contains(digits.count), luhn(digits) { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    nonisolated private static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private func checkSensitivity(_ text: String, entities: [ExtractedEntity]) -> Bool {
        Self.looksLikeSecret(text)
    }

    // MARK: - Title Suggestion

    private func suggestTitle(_ text: String, category: ContentCategory, entities: [ExtractedEntity]) -> String {
        switch category {
        case .code:
            // Prefer the name of the function or class it defines.
            if let funcMatch = text.range(of: #"func\s+(\w+)"#, options: .regularExpression) {
                return L("Function: \(String(text[funcMatch]).replacingOccurrences(of: "func ", with: ""))")
            }
            if let classMatch = text.range(of: #"class\s+(\w+)"#, options: .regularExpression) {
                return L("Class: \(String(text[classMatch]).replacingOccurrences(of: "class ", with: ""))")
            }
            return L("Code Snippet")

        case .links:
            if let urlEntity = entities.first(where: { $0.type == .url }),
               let url = URL(string: urlEntity.value) {
                return url.host() ?? L("Link")
            }
            return L("Link")

        case .contacts:
            if let name = entities.first(where: { $0.type == .personalName }) {
                return L("Contact: \(name.value)")
            }
            if let email = entities.first(where: { $0.type == .email }) {
                return L("Email: \(email.value)")
            }
            return L("Contact")

        case .addresses:
            if let place = entities.first(where: { $0.type == .placeName }) {
                return "📍 \(place.value)"
            }
            return L("Address")

        case .notes:
            let firstLine = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
            return "\(firstLine)..."

        default:
            let preview = String(text.prefix(40))
            return preview.isEmpty ? L("Text") : preview
        }
    }

    // MARK: - Confidence Score

    private func calculateConfidence(entities: [ExtractedEntity], category: ContentCategory) -> Double {
        var confidence: Double = 0.5  // baseline

        // Entities found raises it
        if !entities.isEmpty { confidence += 0.15 * Double(min(entities.count, 3)) }

        // A category other than plain text raises it
        if category != .text { confidence += 0.1 }

        return min(confidence, 1.0)
    }
}

// MARK: - ContentCategory

enum ContentCategory: String, Codable, CaseIterable, Sendable {
    case text
    case code
    case links
    case contacts
    case addresses
    case notes
    case images
    case files

    var displayName: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .links: return "link"
        case .contacts: return "person.2"
        case .addresses: return "mappin.and.ellipse"
        case .notes: return "note.text"
        case .images: return "photo"
        case .files: return "doc"
        }
    }

    var color: String {
        switch self {
        case .text: return "blue"
        case .code: return "green"
        case .links: return "purple"
        case .contacts: return "pink"
        case .addresses: return "orange"
        case .notes: return "cyan"
        case .images: return "yellow"
        case .files: return "gray"
        }
    }
}
