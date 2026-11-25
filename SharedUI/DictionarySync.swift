import Foundation
#if os(iOS)
import UIKit
#endif

/// iPhoneとMacの用語辞書を、iCloud Driveの「マイ音声入力/dictionary.json」で同期する。
/// iCloudの権限(プロファイル)を使わずに済むよう、ふつうのファイルとして読み書きする。
/// - Mac: iCloud Driveのフォルダに直接書く
/// - iPhone: 最初に一度だけ、ファイルアプリでそのフォルダを選んでもらい、ブックマークで覚える
/// 新しいほうを残す(最後に変えた端末の辞書が勝つ)。初めて同期するときだけ、両方の語を合わせる。
@MainActor
final class DictionarySync: ObservableObject {
    static let shared = DictionarySync()
    static let folderName = "マイ音声入力"
    private static let fileName = "dictionary.json"

    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?
    /// 同期で辞書が変わったら増える(画面の読み直しに使う)
    @Published private(set) var revision = 0

    private struct Payload: Codable {
        var updatedAt: Date
        var terms: [Term]
    }

    private var observer: Any?
    private var syncing = false

    private init() {
        observer = NotificationCenter.default.addObserver(forName: TermStore.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in DictionarySync.shared.sync() }
        }
    }

    // MARK: - 同期先のフォルダ

    #if os(iOS)
    private static let bookmarkKey = "sync-folder-bookmark"

    var isConfigured: Bool { UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil }

    /// ファイルアプリで選んだフォルダを覚える
    func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            lastError = nil
            sync()
        } catch {
            lastError = "フォルダを覚えられませんでした: \(error.localizedDescription)"
        }
    }

    func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.syncedOnceKey)
        lastSynced = nil
    }

    var folderName: String? {
        guard let url = resolveFolder() else { return nil }
        return url.lastPathComponent
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T? {
        guard let folder = resolveFolder() else { return nil }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        return try body(folder)
    }
    #else
    var isConfigured: Bool { FileManager.default.fileExists(atPath: Self.iCloudDrive.path) }

    private static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T? {
        guard isConfigured else { return nil }
        let folder = Self.iCloudDrive.appendingPathComponent(Self.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try body(folder)
    }
    #endif

    // MARK: - 同期

    private static let syncedOnceKey = "dictionary-synced-once"

    func sync() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let done: Bool? = try withFolder { folder in
                let file = folder.appendingPathComponent(Self.fileName)
                let remote = try read(file)
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
                    try write(Payload(updatedAt: now, terms: merged), to: file)
                    revision += 1
                } else if let remote, remote.updatedAt > localDate.addingTimeInterval(0.5) {
                    // 相手のほうが新しい
                    TermStore.save(remote.terms, updatedAt: remote.updatedAt)
                    revision += 1
                } else if remote == nil || localDate > remote!.updatedAt.addingTimeInterval(0.5) {
                    // こちらのほうが新しい(または、まだファイルがない)
                    try write(Payload(updatedAt: max(localDate, Date(timeIntervalSince1970: 1)), terms: localTerms), to: file)
                }
                UserDefaults.standard.set(true, forKey: Self.syncedOnceKey)
                return true
            }
            if done == true {
                lastSynced = Date()
                lastError = nil
            }
        } catch {
            lastError = "同期できませんでした: \(error.localizedDescription)"
        }
    }

    private func read(_ file: URL) throws -> Payload? {
        #if os(iOS)
        // iCloudにだけあって、まだこの端末に落ちていないこともある
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        #endif
        var result: Payload?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinatorError) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let data = try Data(contentsOf: url)
                result = try Self.decoder.decode(Payload.self, from: data)
            } catch {
                readError = error
            }
        }
        if let error = coordinatorError ?? readError {
            // 読めないファイルは、こちらの辞書で上書きできるよう「ない」扱いにする
            if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileReadNoSuchFileError { return nil }
            if error is DecodingError { return nil }
            throw error
        }
        return result
    }

    private func write(_ payload: Payload, to file: URL) throws {
        let data = try Self.encoder.encode(payload)
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinatorError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinatorError ?? writeError { throw error }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
