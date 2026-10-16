import SwiftData
import SwiftUI

/// 术语表：原文里出现的启用术语会附在提示词里，要求模型使用固定译法。
struct GlossaryView: View {
    @Environment(AppState.self) private var state
    @Query(sort: \GlossaryTerm.createdAt) private var terms: [GlossaryTerm]
    @State private var selection = Set<PersistentIdentifier>()

    var body: some View {
        VStack(spacing: 0) {
            Table(terms, selection: $selection) {
                TableColumn("启用") { term in
                    Toggle("启用", isOn: Bindable(term).isEnabled)
                        .labelsHidden()
                }
                .width(44)
                TableColumn("原文术语") { term in
                    TextField("原文术语", text: Bindable(term).term)
                        .textFieldStyle(.plain)
                }
                TableColumn("固定译法") { term in
                    TextField("固定译法", text: Bindable(term).translation)
                        .textFieldStyle(.plain)
                }
            }
            .overlay {
                if terms.isEmpty {
                    ContentUnavailableView(
                        "术语表是空的",
                        systemImage: "book.closed",
                        description: Text("添加产品名、人名等需要固定译法的词。")
                    )
                }
            }
            Divider()
            Text("翻译时，原文中出现的启用术语会附在提示词里（不区分大小写）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle("术语表")
        .toolbar {
            Button("添加术语", systemImage: "plus") {
                let term = GlossaryTerm()
                state.context.insert(term)
                try? state.context.save()
                selection = [term.persistentModelID]
            }
            Button("删除所选", systemImage: "minus") {
                for term in terms where selection.contains(term.persistentModelID) {
                    state.context.delete(term)
                }
                try? state.context.save()
                selection = []
            }
            .disabled(selection.isEmpty)
        }
    }
}
