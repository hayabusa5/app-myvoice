import Foundation
import Security

/// 本体アプリとキーボードで共有する設定・辞書・使用量。すべて共有Keychainに置く。
enum AppConfig {
    static var keychainGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "com.takasub5.MyVoice.shared"
    }
}

/// 本体アプリとキーボードの共有Keychainに小さなデータを置く。
/// (App Groupは署名の都合で試作では使わない)
enum SharedKeychain {
    private static let service = "com.takasub5.MyVoice.shared"

    private static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        // 本体アプリとキーボードで共有する。Mac版はアプリ1つなので共有グループは使わない
        query[kSecAttrAccessGroup as String] = AppConfig.keychainGroup
        #endif
        return query
    }

    static func data(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func set(_ data: Data?, _ account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return true }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - APIキー(共有Keychain)

enum APIKeyStore {
    static func load() -> String? {
        guard let data = SharedKeychain.data("groq-api-key"),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedKeychain.set(trimmed.isEmpty ? nil : Data(trimmed.utf8), "groq-api-key")
    }
}

// MARK: - 用語辞書

struct Term: Codable, Identifiable, Hashable {
    var id = UUID()
    /// 実際に出た誤変換(空なら、認識のヒントにだけ使う)
    var wrong: String
    /// 正しい表記
    var right: String
}

enum TermStore {
    private static let key = "terms"

    static let seed: [Term] = [
        Term(wrong: "コーデックス", right: "Codex"),
        Term(wrong: "クロードコード", right: "Claude Code"),
        Term(wrong: "オブシディアン", right: "Obsidian"),
        Term(wrong: "テストフライト", right: "TestFlight"),
        Term(wrong: "クラウドキット", right: "CloudKit"),
        Term(wrong: "グロック", right: "Groq"),
        Term(wrong: "", right: "手首ブザー"),
        Term(wrong: "", right: "まぶしいひつまぶし"),
    ]

    static func load() -> [Term] {
        guard let data = SharedKeychain.data(key),
              let terms = try? JSONDecoder().decode([Term].self, from: data)
        else { return seed }
        return terms
    }

    static func save(_ terms: [Term]) {
        SharedKeychain.set(try? JSONEncoder().encode(terms), key)
    }

    /// Groqの `prompt` は224トークンまでなので、辞書の上から入るだけ入れる。
    private static let promptHead = "以下は日本語の音声入力です。句読点を付けて書きます。用語: "
    private static let promptLimit = 180

    /// 認識のヒントとしてGroqに送る語(辞書の上から順、重複なし)
    static func hintWords(_ terms: [Term]) -> [String] {
        var words: [String] = []
        var length = promptHead.count
        for word in terms.map(\.right) where !word.isEmpty && !words.contains(word) {
            guard length + word.count + 1 <= promptLimit else { break }
            words.append(word)
            length += word.count + 1
        }
        return words
    }

    static func prompt(for terms: [Term], language: SpeechLanguage = .japanese) -> String {
        let words = hintWords(terms)
        switch language {
        case .japanese:
            guard !words.isEmpty else { return "以下は日本語の音声入力です。句読点を付けて書きます。" }
            return promptHead + words.joined(separator: "、") + "、"
        case .english:
            return "This is English dictation with proper punctuation." + (words.isEmpty ? "" : " Terms: " + words.joined(separator: ", ") + ".")
        case .auto:
            // 言語を決めつけない。用語だけを並べる
            return words.joined(separator: ", ")
        }
    }

    /// 誤変換を正しい表記に置き換える。
    static func apply(_ terms: [Term], to text: String) -> String {
        terms.reduce(text) { result, term in
            guard !term.wrong.isEmpty else { return result }
            return result.replacingOccurrences(of: term.wrong, with: term.right, options: .caseInsensitive)
        }
    }
}

// MARK: - 使用量(料金の目安)

enum UsageStore {
    /// Groqは1回あたり最低10秒で課金される
    static let minimumBilledSeconds = 10.0
    /// whisper-large-v3-turbo の料金(1時間あたりのドル)
    static let dollarsPerHour = 0.04

    private static var monthKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return "usage-" + formatter.string(from: Date())
    }

    static func add(seconds: Double) {
        var usage = thisMonth()
        usage.count += 1
        usage.seconds += seconds
        usage.billedSeconds += max(seconds, minimumBilledSeconds)
        SharedKeychain.set(try? JSONEncoder().encode([usage.count, usage.seconds, usage.billedSeconds]), monthKey)
    }

    static func thisMonth() -> (count: Double, seconds: Double, billedSeconds: Double) {
        let values = SharedKeychain.data(monthKey).flatMap { try? JSONDecoder().decode([Double].self, from: $0) } ?? []
        guard values.count == 3 else { return (0, 0, 0) }
        return (values[0], values[1], values[2])
    }

    static func estimatedYen(billedSeconds: Double, yenPerDollar: Double = 150) -> Double {
        billedSeconds / 3600 * dollarsPerHour * yenPerDollar
    }
}

// MARK: - 整形モード

struct FormatMode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// AIへの指示。空なら整形せず、文字起こしをそのまま入れる
    var instruction: String

    var usesAI: Bool { !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum ModeStore {
    private static let key = "modes"
    private static let selectedKey = "selected-mode"

    static let defaults: [FormatMode] = [
        FormatMode(name: "そのまま", instruction: ""),
        FormatMode(name: "整える", instruction: "話し言葉を読みやすい文章に整えてください。「えー」「あの」などのつなぎ言葉と言い直しを消し、句読点を直します。内容・語尾の丁寧さ・言葉の選び方は変えず、要約もしません。"),
        FormatMode(name: "開発指示", instruction: "Claude CodeやCodexなどのAIコーディングエージェントへの、明確な作業指示に書き直してください。目的・やること・条件が分かるように、必要なら箇条書きにします。話していない要件は足しません。"),
        FormatMode(name: "メール", instruction: "丁寧なビジネスメールの本文に整えてください。宛名・署名は、話した中にある場合だけ入れます。話していない内容は足しません。"),
        FormatMode(name: "箇条書き", instruction: "話した内容を整理して、短い箇条書きにしてください。話した順番より、話題ごとのまとまりを優先します。話していない内容は足しません。"),
        FormatMode(name: "note記事", instruction: "noteのブログ記事として読みやすい文章に整えてください。です・ます調で、段落を分けます。話していない事実は足しません。"),
        FormatMode(name: "英語", instruction: "自然な英語に翻訳してください。"),
    ]

    static func load() -> [FormatMode] {
        guard let data = SharedKeychain.data(key),
              let modes = try? JSONDecoder().decode([FormatMode].self, from: data), !modes.isEmpty
        else { return defaults }
        return modes
    }

    static func save(_ modes: [FormatMode]) {
        SharedKeychain.set(try? JSONEncoder().encode(modes), key)
    }

    static func selected(in modes: [FormatMode]) -> FormatMode {
        let id = SharedKeychain.data(selectedKey).flatMap { String(data: $0, encoding: .utf8) }
        return modes.first { $0.id.uuidString == id } ?? modes[0]
    }

    static func select(_ mode: FormatMode) {
        SharedKeychain.set(Data(mode.id.uuidString.utf8), selectedKey)
    }
}

// MARK: - 認識する言語

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case auto, japanese, english

    var id: String { rawValue }
    /// Groqに渡す言語コード。自動のときは渡さない
    var code: String? {
        switch self {
        case .auto: return nil
        case .japanese: return "ja"
        case .english: return "en"
        }
    }
    var label: String {
        switch self {
        case .auto: return "自動"
        case .japanese: return "日本語"
        case .english: return "英語"
        }
    }
    /// キーボードのボタンに出す短い表示
    var shortLabel: String {
        switch self {
        case .auto: return "自動"
        case .japanese: return "日"
        case .english: return "EN"
        }
    }
    var next: SpeechLanguage {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    private static let key = "speech-language"
    static var current: SpeechLanguage {
        get { SharedKeychain.data(key).flatMap { SpeechLanguage(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .auto }
        set { SharedKeychain.set(Data(newValue.rawValue.utf8), key) }
    }
}

// MARK: - マイクの選び方(iPhone)

enum MicPreference {
    private static let key = "prefer-builtin-mic"
    /// trueなら、AirPodsなどがつながっていてもiPhone本体のマイクで録音する
    static var preferBuiltIn: Bool {
        get { SharedKeychain.data(key).map { $0 == Data([1]) } ?? false }
        set { SharedKeychain.set(Data([newValue ? 1 : 0]), key) }
    }
}

#if os(iOS)
/// キーボードを追加済みか、フルアクセスが付いているか(アプリの「準備」の印に使う)
enum KeyboardStatus {
    static let bundleID = "com.takasub5.MyVoice.Keyboard"
    private static let fullAccessKey = "keyboard-full-access"

    /// 設定で追加済みのキーボードの一覧に入っているか
    static var isAdded: Bool {
        let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        return keyboards.contains(bundleID)
    }

    /// キーボードが最後に開いたとき、フルアクセスが付いていたか(キーボード側が書く)
    static var hasFullAccess: Bool {
        get { SharedKeychain.data(fullAccessKey) == Data([1]) }
        set { SharedKeychain.set(Data([newValue ? 1 : 0]), fullAccessKey) }
    }
}
#endif
