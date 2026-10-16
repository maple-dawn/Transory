import SwiftData
import SwiftUI
import TransoryCore

/// 历史记录；`favoritesOnly` 为 true 时作为收藏页。
struct HistoryView: View {
    let favoritesOnly: Bool

    @Environment(AppState.self) private var state
    @Query(sort: \HistoryEntry.createdAt, order: .reverse) private var entries: [HistoryEntry]
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        entries.filter { entry in
            (!favoritesOnly || entry.isFavorite)
                && (search.isEmpty
                    || entry.sourceText.localizedCaseInsensitiveContains(search)
                    || entry.translatedText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { entry in
                HistoryRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { state.open(entry) }
                    .contextMenu {
                        Button("在翻译页打开") { state.open(entry) }
                        Button("复制译文") { state.copy(entry.translatedText) }
                        Button("复制原文") { state.copy(entry.sourceText) }
                        Button(entry.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(entry) }
                        Divider()
                        Button("删除", role: .destructive) {
                            state.context.delete(entry)
                            try? state.context.save()
                        }
                    }
            }
        }
        .overlay {
            if filtered.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if favoritesOnly {
                    ContentUnavailableView("还没有收藏", systemImage: "star", description: Text("在译文底栏点星标，或在历史记录里右键收藏。"))
                } else {
                    ContentUnavailableView("还没有翻译记录", systemImage: "clock", description: Text("完成的翻译会自动记在这里。"))
                }
            }
        }
        .searchable(text: $search, prompt: "搜索原文或译文")
        .navigationTitle(favoritesOnly ? "收藏" : "历史记录")
        .toolbar {
            if !favoritesOnly {
                Button("清空历史", systemImage: "trash") { confirmClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("清空全部历史记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { state.clearHistory() }
        } message: {
            Text("收藏的记录会保留。")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.sourceText)
                .lineLimit(2)
            Text(entry.translatedText)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if entry.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                Text([entry.origin.displayName, entry.model.isEmpty ? entry.providerName : entry.model].joined(separator: " · "))
                Spacer()
                Text(entry.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
