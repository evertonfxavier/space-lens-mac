import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let analysis = model.analysis {
            let items = analysis.categoryBytes.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            let total = Double(max(1, analysis.scannedBytes))
            let selected = model.focusedCategory ?? items.first?.key
            HSplitView {
                List(selection: Binding<Category?>(get: { selected }, set: { model.focusedCategory = $0 })) {
                    ForEach(items, id: \.key) { category, bytes in
                        HStack(spacing: 10) {
                            Image(systemName: category.icon).foregroundStyle(category.color).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(category.title)
                                    Spacer()
                                    Text(Fmt.size(bytes)).monospacedDigit()
                                }
                                HStack(spacing: 8) {
                                    SizeBar(fraction: Double(bytes) / total, color: category.color)
                                    Text(Double(bytes) / total, format: .percent.precision(.fractionLength(0)))
                                        .font(.caption).foregroundStyle(.secondary).frame(
                                            width: 34, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.vertical, 3).tag(category)
                    }
                }
                .frame(minWidth: 330, idealWidth: 360, maxWidth: 440)
                if let selected {
                    CategoryDetail(
                        category: selected, items: analysis.topItems[selected] ?? [],
                        total: analysis.categoryBytes[selected] ?? 0
                    )
                    .frame(minWidth: 380)
                }
            }
        } else {
            EmptyAnalysis(text: L("Analise o disco para ver o consumo por categoria."))
        }
    }
}

struct CategoryDetail: View {
    @EnvironmentObject var model: AppModel
    let category: Category
    let items: [CategoryItem]
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: category.icon).foregroundStyle(category.color)
                    Text(category.title).font(.title3.weight(.semibold))
                    Spacer()
                    Text(Fmt.size(total)).font(.title3).monospacedDigit()
                }
                Text(L("Os maiores itens desta categoria. Clique em “Explorar” para abrir a pasta.")).font(.caption)
                    .foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            if items.isEmpty {
                Text(L("Esta categoria é feita de muitos arquivos pequenos.")).foregroundStyle(.secondary).padding(16)
                Spacer()
            } else {
                List(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Text(
                                (item.path as NSString).deletingLastPathComponent.replacingOccurrences(
                                    of: model.home, with: "~")
                            )
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        SafetyBadge(safety: item.safety)
                        Text(Fmt.size(item.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                    .contextMenu {
                        Button(L("Mostrar no Finder")) { revealInFinder(item.path) }
                        Button(L("Abrir no Explorar")) {
                            model.explorerPath =
                                item.isDirectory ? item.path : (item.path as NSString).deletingLastPathComponent
                            model.section = .explorer
                        }
                        Button(L("Copiar caminho")) { copyToPasteboard(item.path) }
                    }
                }
            }
        }
    }
}
