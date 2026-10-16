import SwiftUI
import TransoryCore

/// 「添加模型服务」：按分组列出服务模板，选中后添加并在当前窗口里打开。
struct AddProviderSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let scope: WindowScope
    let onAdded: (String) -> Void

    @State private var picked: String?

    private var pickedTemplate: ProviderTemplate? {
        ProviderTemplate.all.first { $0.id == picked }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("添加模型服务").font(.headline)
                Text("选一个服务，添加后在列表里填 Key 和模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ProviderTemplate.Group.allCases, id: \.self) { group in
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(ProviderTemplate.all.filter { $0.group == group }) { template in
                                TemplateTile(
                                    template: template,
                                    isAdded: state.isAdded(template),
                                    isSelected: picked == template.id,
                                    select: { picked = template.id },
                                    add: { picked = template.id; add() }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()

            HStack(spacing: 8) {
                Text(pickedTemplate.map { "添加「\($0.name)」，并在\(scope.title)中打开" } ?? "选择一个服务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pickedTemplate == nil)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
    }

    private func add() {
        guard let template = pickedTemplate, !state.isAdded(template) else { return }
        let config = state.addProvider(from: template, enableIn: scope)
        onAdded(config.id)
        dismiss()
    }
}

private struct TemplateTile: View {
    let template: ProviderTemplate
    let isAdded: Bool
    let isSelected: Bool
    let select: () -> Void
    let add: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                ProviderMonogram(name: template.name, id: template.id, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(isAdded ? "已添加" : template.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .opacity(isAdded ? 0.5 : 1)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !isAdded { add() } })
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
