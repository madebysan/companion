import Foundation

final class GenerationHistoryStore {
    static let shared = GenerationHistoryStore()

    struct Entry: Codable, Identifiable {
        let id: UUID
        let createdAt: Date
        let actionLabel: String
        let provider: String
        let model: String
        let selectedWordCount: Int
        let hadImages: Bool
        let imageFileNames: [String]
        let result: String
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        migrateLegacyHistoryIfNeeded()
    }

    func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: historyURL()) else { return [] }
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    func add(
        result: String,
        actionLabel: String,
        provider: UserSettings.Provider,
        model: String,
        selectedWordCount: Int,
        imageFileNames: [String]
    ) {
        let entry = Entry(
            id: UUID(),
            createdAt: Date(),
            actionLabel: actionLabel,
            provider: provider.shortLabel,
            model: model,
            selectedWordCount: selectedWordCount,
            hadImages: !imageFileNames.isEmpty,
            imageFileNames: imageFileNames,
            result: result
        )

        var current = entries()
        current.insert(entry, at: 0)
        save(current)
    }

    func clear() {
        try? FileManager.default.removeItem(at: historyURL())
    }

    private func save(_ entries: [Entry]) {
        do {
            let url = historyURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(entries)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Failed to save Companion history: \(error)")
        }
    }

    private func historyURL() -> URL {
        historyURL(appSupportFolder: "Companion")
    }

    private func legacyHistoryURL() -> URL {
        historyURL(appSupportFolder: "CompanionV2")
    }

    private func historyURL(appSupportFolder: String) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return base
            .appendingPathComponent(appSupportFolder, isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func migrateLegacyHistoryIfNeeded() {
        let currentURL = historyURL()
        let legacyURL = legacyHistoryURL()
        guard !FileManager.default.fileExists(atPath: currentURL.path),
              FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        do {
            try FileManager.default.createDirectory(
                at: currentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: legacyURL, to: currentURL)
        } catch {
            NSLog("Failed to migrate Companion history: \(error)")
        }
    }
}
