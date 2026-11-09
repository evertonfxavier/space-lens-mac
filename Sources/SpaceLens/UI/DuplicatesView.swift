import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.analysis == nil {
            EmptyAnalysis(text: L("Analise o disco para procurar arquivos duplicados."))
        } else {
            switch model.duplicates {
            case .idle:
                ContentUnavailableView {
                    Label(L("Arquivos duplicados"), systemImage: "doc.on.doc")
                } description: {
                    Text(
                        L(
                            "Compara os arquivos de 1 MB ou mais da análise pelo conteúdo (não só pelo nome). Cópias idênticas ocupam espaço em dobro."
                        )
                    )
                } actions: {
                    Button(L("Procurar duplicados")) { model.findDuplicates() }.buttonStyle(.borderedProminent)
                }
            case .running(let done, let total):
                VStack(spacing: 14) {
                    ProgressView(value: Double(done), total: Double(max(1, total))).frame(width: 320)
                    Text(L("Comparando conteúdo… %lld de %lld", done, total)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let groups):
                if groups.isEmpty {
                    ContentUnavailableView(
                        L("Nenhum duplicado"), systemImage: "checkmark.seal",
                        description: Text(L("Não encontrei arquivos idênticos de 1 MB ou mais.")))
                } else {
                    results(groups)
                }
            }
        }
    }

    /// "All" means every copy except the oldest of each group, which is the one that stays. Anything in between,
    /// like keeping a different copy, shows as "some".
    private func checkState(_ groups: [DuplicateGroup]) -> CheckState {
        let ticked = groups.reduce(0) { $0 + $1.files.filter { model.duplicateSelection.contains($0.path) }.count }
        if ticked == 0 { return .none }
        let exact = groups.allSatisfy { group in
            group.files.enumerated().allSatisfy { index, file in
                model.duplicateSelection.contains(file.path) == (index > 0)
            }
        }
        return exact ? .all : .some
    }

    private func setAll(_ groups: [DuplicateGroup], _ on: Bool) {
        for group in groups {
            for (index, file) in group.files.enumerated() {
                if on && index > 0 {
                    model.duplicateSelection.insert(file.path)
                } else {
                    model.duplicateSelection.remove(file.path)
                }
            }
        }
    }

    private func selectAllBar(_ groups: [DuplicateGroup]) -> some View {
        let candidates = groups.reduce(0) { $0 + max(0, $1.files.count - 1) }
        let ticked = groups.reduce(0) { $0 + $1.removable(selected: model.duplicateSelection).count }
        return HStack(spacing: 10) {
            SelectionBox(state: checkState(groups)) { setAll(groups, checkState(groups) != .all) }
            Text(L("Marcar tudo")).font(.callout.weight(.medium))
            Spacer()
            Text(L("%lld de %lld itens marcados", ticked, candidates))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4).listRowSeparator(.hidden)
    }

    private func results(_ groups: [DuplicateGroup]) -> some View {
        let removable = groups.flatMap { $0.removable(selected: model.duplicateSelection) }
        let size = groups.reduce(Int64(0)) { total, group in
            total + Int64(group.removable(selected: model.duplicateSelection).count) * group.size
        }
        return List {
            Text(
                L(
                    "Em cada grupo a cópia mais antiga fica de fora (é provavelmente o original). Cópias APFS clonadas podem dividir o mesmo espaço, então o ganho real pode ser menor que o mostrado. Tudo vai para a Lixeira."
                )
            )
            .font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
            selectAllBar(groups)
            ForEach(groups) { group in
                SwiftUI.Section {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 10) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { model.duplicateSelection.contains(file.path) },
                                    set: { on in
                                        if on {
                                            model.duplicateSelection.insert(file.path)
                                        } else {
                                            model.duplicateSelection.remove(file.path)
                                        }
                                    })
                            ).toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text((file.path as NSString).lastPathComponent).lineLimit(1)
                                Text(
                                    (file.path as NSString).deletingLastPathComponent.replacingOccurrences(
                                        of: model.home, with: "~")
                                )
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            if index == 0 { Badge(text: L("Original provável"), color: .green) }
                            Text(Fmt.ago(file.modified)).font(.caption).foregroundStyle(.secondary)
                            Button {
                                revealInFinder(file.path)
                            } label: {
                                Image(systemName: "magnifyingglass.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        SelectionBox(state: checkState([group])) { setAll([group], checkState([group]) != .all) }
                        Text(L("%lld cópias de %@", group.files.count, Fmt.size(group.size))).font(.headline)
                        Spacer()
                        Text(L("até %@ a liberar", Fmt.size(group.wasted))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(LocalizedStringKey(L("%lld arquivo(s) marcado(s) · até **%@**", removable.count, Fmt.size(size))))
                Spacer()
                Button(L("Procurar de novo")) {
                    model.duplicates = .idle
                    model.findDuplicates()
                }
                Button {
                    Task { await model.trashDuplicates() }
                } label: {
                    Label(L("Mover para a Lixeira"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).disabled(removable.isEmpty || model.isBusy)
            }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
    }
}
