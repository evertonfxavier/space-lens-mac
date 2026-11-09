import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.analysis == nil {
            EmptyAnalysis(text: "Analise o disco para procurar arquivos duplicados.")
        } else {
            switch model.duplicates {
            case .idle:
                ContentUnavailableView {
                    Label("Arquivos duplicados", systemImage: "doc.on.doc")
                } description: {
                    Text(
                        "Compara os arquivos de 1 MB ou mais da análise pelo conteúdo (não só pelo nome). Cópias idênticas ocupam espaço em dobro."
                    )
                } actions: {
                    Button("Procurar duplicados") { model.findDuplicates() }.buttonStyle(.borderedProminent)
                }
            case .running(let done, let total):
                VStack(spacing: 14) {
                    ProgressView(value: Double(done), total: Double(max(1, total))).frame(width: 320)
                    Text("Comparando conteúdo… \(done) de \(total)").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let groups):
                if groups.isEmpty {
                    ContentUnavailableView(
                        "Nenhum duplicado", systemImage: "checkmark.seal",
                        description: Text("Não encontrei arquivos idênticos de 1 MB ou mais."))
                } else {
                    results(groups)
                }
            }
        }
    }

    private func results(_ groups: [DuplicateGroup]) -> some View {
        let removable = groups.flatMap { $0.removable(selected: model.duplicateSelection) }
        let size = groups.reduce(Int64(0)) { total, group in
            total + Int64(group.removable(selected: model.duplicateSelection).count) * group.size
        }
        return List {
            Text(
                "Em cada grupo a cópia mais antiga fica de fora (é provavelmente o original). Cópias APFS clonadas podem dividir o mesmo espaço, então o ganho real pode ser menor que o mostrado. Tudo vai para a Lixeira."
            )
            .font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
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
                            if index == 0 { Badge(text: "Original provável", color: .green) }
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
                    HStack {
                        Text("\(group.files.count) cópias de \(Fmt.size(group.size))").font(.headline)
                        Spacer()
                        Text("até \(Fmt.size(group.wasted)) a liberar").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(removable.count) arquivo(s) marcado(s) · até **\(Fmt.size(size))**")
                Spacer()
                Button("Procurar de novo") {
                    model.duplicates = .idle
                    model.findDuplicates()
                }
                Button {
                    Task { await model.trashDuplicates() }
                } label: {
                    Label("Mover para a Lixeira", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).disabled(removable.isEmpty || model.isBusy)
            }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
    }
}
