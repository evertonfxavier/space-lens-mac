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
    /// What the confirmation dialog is about: one item or a whole group.
    @State private var pending: [CategoryItem]?

    /// Items the safety guard lets you move to the Trash. System files and the like stay greyed out.
    private var deletable: [CategoryItem] { items.filter { model.trashVerdict(path: $0.path).isAllowed } }
    private var picked: [CategoryItem] { deletable.filter { model.categorySelection.contains($0.path) } }

    private var checkState: CheckState {
        picked.isEmpty ? .none : (picked.count == deletable.count ? .all : .some)
    }

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
                selectionBar
                Divider()
                List(items) { item in row(item) }
            }
        }
        .confirmationDialog(
            pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible, presenting: pending
        ) { targets in
            Button(
                L("Mover %@ para a Lixeira", Fmt.size(targets.reduce(0) { $0 + $1.size })), role: .destructive
            ) {
                Task {
                    await model.trashItems(targets.map { CleanupItem(path: $0.path, size: $0.size) })
                }
            }
        } message: { _ in
            Text(L("Você pode recuperar pela Lixeira. O espaço só é liberado quando a Lixeira for esvaziada."))
        }
    }

    private var pendingTitle: String {
        guard let pending else { return "" }
        return pending.count == 1
            ? L("Mover “%@” para a Lixeira?", pending[0].name) : L("Mover %lld itens para a Lixeira?", pending.count)
    }

    /// The group controls: tick everything that may go, and trash what is ticked in one go.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            SelectionBox(state: checkState) {
                if checkState == .all {
                    model.categorySelection.subtract(deletable.map(\.path))
                } else {
                    model.categorySelection.formUnion(deletable.map(\.path))
                }
            }
            .disabled(deletable.isEmpty)
            Text(L("Marcar tudo")).font(.callout.weight(.medium))
            Text(L("%lld de %lld itens marcados", picked.count, deletable.count))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button(role: .destructive) {
                pending = picked
            } label: {
                Label(
                    picked.isEmpty
                        ? L("Mover para a Lixeira")
                        : L(
                            "Mover para a Lixeira (%lld · %@)", picked.count,
                            Fmt.size(picked.reduce(0) { $0 + $1.size })),
                    systemImage: "trash")
            }
            .disabled(picked.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func row(_ item: CategoryItem) -> some View {
        let verdict = model.trashVerdict(path: item.path)
        let allowed = verdict.isAllowed
        return HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.categorySelection.contains(item.path) },
                    set: { on in
                        if on {
                            model.categorySelection.insert(item.path)
                        } else {
                            model.categorySelection.remove(item.path)
                        }
                    })
            )
            .toggleStyle(.checkbox).labelsHidden().disabled(!allowed)
            .help(allowed ? "" : denied(verdict))
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(Fmt.shortPath((item.path as NSString).deletingLastPathComponent, home: model.home))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            SafetyBadge(safety: item.safety)
            Text(Fmt.size(item.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Button {
                pending = [item]
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!allowed || model.isBusy)
            .help(allowed ? L("Mover para a Lixeira") : denied(verdict))
        }
        .contextMenu {
            Button(L("Mostrar no Finder")) { revealInFinder(item.path) }
            Button(L("Abrir no Explorar")) {
                model.explorerPath = item.isDirectory ? item.path : (item.path as NSString).deletingLastPathComponent
                model.section = .explorer
            }
            Button(L("Copiar caminho")) { copyToPasteboard(item.path) }
            if allowed {
                Divider()
                Button(L("Mover para a Lixeira"), role: .destructive) { pending = [item] }
            }
        }
    }

    private func denied(_ verdict: SafetyGuard.Verdict) -> String {
        if case .denied(let reason) = verdict { return reason }
        return ""
    }
}
