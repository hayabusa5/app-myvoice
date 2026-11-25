import Foundation

/// iPhoneとMacの用語辞書を、iCloudのキー値ストア(NSUbiquitousKeyValueStore)で同期する。
/// 両方のアプリに同じ `com.apple.developer.ubiquity-kvstore-identifier` を付けている。
/// 新しいほうを残す(最後に変えた端末の辞書が勝つ)。初めて同期するときだけ、両方の語を合わせる。
@MainActor
final class DictionarySync: ObservableObject {
    static let shared = DictionarySync()
    private static let storeKey = "dictionary"
    private static let syncedOnceKey = "dictionary-synced-once-icloud"

    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?
    /// 同期で辞書が変わったら増える(画面の読み直しに使う)
    @Published private(set) var revision = 0

    private struct Payload: Codable {
        var updatedAt: Date
        var terms: [Term]
    }

    private let store = NSUbiquitousKeyValueStore.default
    private var observers: [Any] = []
    private var syncing = false

    private init() {
        // この端末で辞書を変えたら書き出す
        observers.append(NotificationCenter.default.addObserver(forName: TermStore.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in DictionarySync.shared.sync() }
        })
        // ほかの端末の変更がiCloudから届いたら取り込む
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor in
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    DictionarySync.shared.lastError = "iCloudの容量の上限を超えました"
                } else if reason == NSUbiquitousKeyValueStoreAccountChange {
                    DictionarySync.shared.lastError = "iCloudのアカウントが変わりました"
                } else {
                    DictionarySync.shared.sync()
                }
            }
        })
        store.synchronize()
    }

    /// iCloudにサインインしているか
    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func sync() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        guard isAvailable else {
            lastError = "iCloudにサインインしていません"
            return
        }
        store.synchronize()

        let remote = store.data(forKey: Self.storeKey).flatMap { try? Self.decoder.decode(Payload.self, from: $0) }
        let localTerms = TermStore.load()
        let localDate = TermStore.updatedAt
        let syncedOnce = UserDefaults.standard.bool(forKey: Self.syncedOnceKey)

        if let remote, !syncedOnce {
            // 初めての同期: どちらの語も失わないように合わせる(この端末の並びを先に)
            var merged = localTerms
            for term in remote.terms where !merged.contains(where: { $0.right == term.right && $0.wrong == term.wrong }) {
                merged.append(term)
            }
            let now = Date()
            TermStore.save(merged, updatedAt: now)
            write(Payload(updatedAt: now, terms: merged))
            if merged != localTerms { revision += 1 }
        } else if let remote, remote.updatedAt > localDate.addingTimeInterval(0.5) {
            // 相手のほうが新しい
            TermStore.save(remote.terms, updatedAt: remote.updatedAt)
            revision += 1
        } else if remote == nil || localDate > remote!.updatedAt.addingTimeInterval(0.5) {
            // こちらのほうが新しい(または、まだ何もない)
            write(Payload(updatedAt: max(localDate, Date(timeIntervalSince1970: 1)), terms: localTerms))
        }
        UserDefaults.standard.set(true, forKey: Self.syncedOnceKey)
        lastSynced = Date()
        lastError = nil
    }

    private func write(_ payload: Payload) {
        guard let data = try? Self.encoder.encode(payload) else { return }
        store.set(data, forKey: Self.storeKey)
        store.synchronize()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
