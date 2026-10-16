import Foundation
import SwiftData

/// 翻译从哪里发起。
enum HistoryOrigin: String, Codable, CaseIterable {
    case main, popover, ocr, menubar

    var displayName: String {
        switch self {
        case .main: "主窗口"
        case .popover: "划词"
        case .ocr: "截图"
        case .menubar: "菜单栏"
        }
    }
}

/// 一条翻译记录。
@Model
final class HistoryEntry {
    var createdAt: Date
    var sourceText: String
    var translatedText: String
    var sourceCode: String
    var targetCode: String
    var providerID: String
    var providerName: String
    var model: String
    var isFavorite: Bool
    var originRaw: String

    var origin: HistoryOrigin { HistoryOrigin(rawValue: originRaw) ?? .main }

    init(
        sourceText: String,
        translatedText: String,
        sourceCode: String,
        targetCode: String,
        providerID: String,
        providerName: String,
        model: String,
        origin: HistoryOrigin
    ) {
        self.createdAt = .now
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceCode = sourceCode
        self.targetCode = targetCode
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.isFavorite = false
        self.originRaw = origin.rawValue
    }
}

/// 术语表中的一条。
@Model
final class GlossaryTerm {
    var term: String
    var translation: String
    var isEnabled: Bool
    var createdAt: Date

    init(term: String = "", translation: String = "", isEnabled: Bool = true) {
        self.term = term
        self.translation = translation
        self.isEnabled = isEnabled
        self.createdAt = .now
    }
}

enum Store {
    /// 数据库放在 ~/Library/Application Support/Transory/ 下。
    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema([HistoryEntry.self, GlossaryTerm.self])
        #if DEBUG
        if SnapshotTool.isActive {
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        #endif
        let directory = URL.applicationSupportDirectory.appending(path: "Transory", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "Transory.store"))
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // 数据库打不开时退回内存存储，保证 App 能启动。
            print("无法打开数据库：\(error)")
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }
}
