import SwiftUI

struct RecommendationsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.analysis == nil {
            EmptyAnalysis(text: L("Analise o disco para ver o que você pode apagar."))
        } else if model.recommendations.isEmpty {
            ContentUnavailableView(
                L("Nada para limpar"), systemImage: "checkmark.seal",
                description: Text(L("Não encontrei nada que valha a pena apagar. Seu Mac está em ordem.")))
        } else {
            List {
                legend
                selectAllBar
                ForEach([Safety.safe, .review], id: \.self) { safety in
                    let recs = model.recommendations.filter { $0.safety == safety }
                    if !recs.isEmpty {
                        SwiftUI.Section {
                            ForEach(recs) { rec in RecommendationRow(rec: rec, isExpanded: binding(rec.id)) }
                        } header: {
                            HStack(spacing: 8) {
                                SelectionBox(state: model.checkState(recs)) {
                                    model.selectAll(recs, model.checkState(recs) != .all)
                                }
                                Image(systemName: safety.icon).foregroundStyle(safety.color)
                                Text(safety == .safe ? L("Pode apagar com segurança") : L("Revise antes de apagar"))
                                    .font(.headline)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    /// One checkbox for everything: ticks or clears every item of every recommendation.
    private var selectAllBar: some View {
        let recs = model.recommendations
        let counts = model.pickedCount(recs)
        return HStack(spacing: 10) {
            SelectionBox(state: model.checkState(recs)) { model.selectAll(recs, model.checkState(recs) != .all) }
            Text(L("Marcar tudo")).font(.callout.weight(.medium))
            Spacer()
            Text(L("%lld de %lld itens marcados", counts.picked, counts.total))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private var legend: some View {
        Text(
            L(
                "Cada item explica o que é e o que acontece se você apagar. Itens “Revise antes” começam desmarcados e, por padrão, vão para a Lixeira. O SpaceLens nunca toca em sistema, chaves, iCloud e Fotos."
            )
        )
        .font(.callout).foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedRecs.contains(id) },
            set: { if $0 { model.expandedRecs.insert(id) } else { model.expandedRecs.remove(id) } })
    }

    private var footer: some View {
        HStack {
            Text(LocalizedStringKey(L("Marcado para limpar: **%@**", Fmt.size(model.totalSelectedSize))))
            Spacer()
            let quick = model.quickCleanSize
            Button {
                Task { await model.quickClean() }
            } label: {
                Label(L("Limpar o seguro marcado (%@)", Fmt.size(quick)), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent).disabled(quick == 0 || model.isBusy)
        }
        .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
}

/// A checkbox that can also show "some": ticked, dashed or empty. Clicking ticks everything unless everything is
/// already ticked.
struct SelectionBox: View {
    var state: CheckState
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(state == .all ? L("Desmarcar") : L("Marcar todos"))
        .accessibilityLabel(state == .all ? L("Desmarcar") : L("Marcar todos"))
    }

    private var symbol: String {
        switch state {
        case .none: return "square"
        case .some: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }
}

struct EmptyAnalysis: View {
    @EnvironmentObject var model: AppModel
    var text: String

    var body: some View {
        ContentUnavailableView {
            Label(L("Sem análise ainda"), systemImage: "magnifyingglass")
        } description: {
            Text(text)
        } actions: {
            Button(L("Analisar agora")) { model.startScan() }.buttonStyle(.borderedProminent).disabled(model.isScanning)
        }
    }
}

struct RecommendationRow: View {
    @EnvironmentObject var model: AppModel
    let rec: Recommendation
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                consequence
                HStack(spacing: 12) {
                    Button(L("Marcar todos")) { model.selectAll(rec, true) }
                    Button(L("Desmarcar")) { model.selectAll(rec, false) }
                }.buttonStyle(.link).font(.caption)
                ForEach(rec.items.prefix(100)) { item in ItemRow(rec: rec, item: item) }
                if rec.items.count > 100 {
                    Text(L("+ %@ itens menores", rec.items.count - 100)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8).padding(.leading, 4)
        } label: {
            header
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SelectionBox(state: model.checkState([rec])) { model.selectAll(rec, model.checkState([rec]) != .all) }
                .padding(.top, 2)
            Image(systemName: rec.category.icon).font(.title3).foregroundStyle(rec.category.color).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rec.title).font(.headline)
                    if rec.needsAdmin { Badge(text: L("Pede senha ou digital"), color: .purple, icon: "lock.fill") }
                    if rec.isCommand && !rec.needsAdmin {
                        Badge(text: L("Usa %@", rec.command?.tool ?? ""), color: .gray, icon: "terminal")
                    }
                    Badge(
                        text: modeText, color: .secondary,
                        icon: rec.mode == .trash || model.settings.alwaysUseTrash && !rec.needsAdmin
                            ? "trash" : "bolt.fill")
                }
                Text(rec.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(
                    rec.sizeIsReference && rec.totalSize == 0
                        ? "—" : (rec.sizeIsReference ? L("até ") : "") + Fmt.size(rec.totalSize)
                )
                .font(.title3.weight(.semibold)).monospacedDigit()
                Button {
                    Task { await model.clean(rec) }
                } label: {
                    Text(cleanLabel)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent).tint(rec.safety == .safe ? .green : .orange)
                .disabled(model.selectedItems(rec).isEmpty || model.isBusy)
            }
        }
    }

    private var modeText: String {
        if rec.needsAdmin { return L("Apaga de vez") }
        if rec.isCommand { return L("Executa comando") }
        return (rec.mode == .trash || model.settings.alwaysUseTrash) ? L("Vai para a Lixeira") : L("Apaga de vez")
    }

    private var cleanLabel: String {
        let n = model.selectedItems(rec).count
        if rec.isCommand { return rec.id == "snapshots.tm" ? L("Apagar %lld", n) : L("Executar") }
        return n == 0 ? L("Nada marcado") : L("Limpar %@", Fmt.size(model.selectedSize(rec)))
    }

    private var consequence: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !rec.consequence.isEmpty {
                Label(rec.consequence, systemImage: "info.circle").font(.callout)
            }
            if let command = rec.command {
                Label(L("Comando: %@", command.display), systemImage: "terminal").font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(rec.safety.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let rec: Recommendation
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.selection[rec.id]?.contains(item.path) ?? false },
                    set: { _ in model.toggle(rec, item) }
                )
            ).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label.map { "\(item.name) — \($0)" } ?? item.name).lineLimit(1).truncationMode(.middle)
                Text(
                    item.path.hasPrefix("snapshot:")
                        ? L("Instantâneo local")
                        : (item.path as NSString).deletingLastPathComponent.replacingOccurrences(
                            of: model.home, with: "~")
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let modified = item.modified ?? item.changed {
                Text(Fmt.ago(modified)).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.size > 0 ? Fmt.size(item.size) : "—").monospacedDigit().frame(width: 76, alignment: .trailing)
            if !item.path.hasPrefix("snapshot:") {
                Button {
                    revealInFinder(item.path)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless).help(L("Mostrar no Finder"))
            }
        }
    }
}
