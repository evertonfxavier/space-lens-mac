import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let analysis = model.analysis, let usage = model.usage {
                    StorageCard(usage: usage, analysis: analysis)
                    FreeableCard(analysis: analysis)
                    CategoryGrid(analysis: analysis)
                } else if model.isScanning {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Analisando seu disco…")).font(.title3.weight(.semibold))
                            Text(L("Os resultados aparecem aqui assim que terminar. Você pode continuar usando o Mac."))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    WelcomeCard()
                }
                if let summary = model.summary, model.analysis == nil, !model.isScanning {
                    LastScanCard(summary: summary)
                }
            }
            .padding(24)
        }
    }
}

struct WelcomeCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "internaldrive").font(.system(size: 34)).foregroundStyle(.tint)
                Text(L("Veja o que ocupa o espaço do seu Mac")).font(.title2.weight(.semibold))
                Text(
                    L(
                        "O SpaceLens analisa o disco, separa tudo por categoria e diz o que você pode apagar sem medo, o que merece uma olhada e o que não deve ser tocado. Nada é apagado sem sua confirmação."
                    )
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker(L("Analisar"), selection: $model.settings.scope) {
                        ForEach(AppSettings.ScanScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 320).labelsHidden()
                    Button {
                        model.startScan()
                    } label: {
                        Label(L("Analisar agora"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }
}

struct LastScanCard: View {
    let summary: ScanSummary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Última análise")).font(.headline)
                Text(
                    verbatim:
                        "\(Fmt.dateTimeString(summary.date)) · \(summary.scope.title) · \(Int(summary.duration)) s"
                )
                .foregroundStyle(.secondary)
                if summary.safeFreeable > 0 {
                    Text(
                        L(
                            "Na época havia %@ para liberar com segurança. Analise de novo para ver o estado atual.",
                            Fmt.size(summary.safeFreeable))
                    )
                    .font(.callout)
                }
            }
        }
    }
}

struct StorageCard: View {
    @EnvironmentObject var model: AppModel
    let usage: DiskUsage
    let analysis: Analysis

    private var segments: [Segment] {
        let total = Double(max(1, usage.total))
        var out = analysis.categoryBytes.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map {
            Segment(
                id: $0.key.rawValue, color: $0.key.color, fraction: Double($0.value) / total,
                label: "\($0.key.title): \(Fmt.size($0.value))")
        }
        let unscanned = usage.used - analysis.scannedBytes
        if unscanned > 0 {
            out.append(
                Segment(
                    id: "unscanned", color: Color(nsColor: .tertiaryLabelColor), fraction: Double(unscanned) / total,
                    label: L("Fora da análise: %@", Fmt.size(unscanned))))
        }
        return out
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Macintosh HD").font(.title3.weight(.semibold))
                        Text(L("%@ usados de %@", Fmt.size(usage.used), Fmt.size(usage.total))).foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.size(usage.availableImportant)).font(
                            .system(size: 30, weight: .semibold, design: .rounded)
                        )
                        .foregroundStyle(model.isLowOnSpace ? .red : .primary)
                        Text(
                            usage.purgeable > 0
                                ? L("livres (%@ liberáveis pelo macOS)", Fmt.size(usage.purgeable)) : "livres"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SegmentedBar(segments: segments, height: 18)
                if model.settings.scope == .home {
                    Text(
                        L(
                            "A análise cobre sua pasta pessoal. O restante do disco (sistema, apps e outros usuários) aparece como “fora da análise”. Mude em Ajustes para analisar o disco inteiro."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FreeableCard: View {
    @EnvironmentObject var model: AppModel
    let analysis: Analysis

    var body: some View {
        let quick = model.quickCleanSize
        Card {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 34)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    if analysis.safeFreeable > 0 {
                        Text(L("Dá para liberar %@ com segurança", Fmt.size(analysis.safeFreeable))).font(
                            .title3.weight(.semibold))
                        Text(
                            L(
                                "Caches, logs, builds e outros arquivos que o macOS e seus apps recriam sozinhos. Nada seu é perdido."
                            )
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("Nada seguro para limpar agora")).font(.title3.weight(.semibold))
                        Text(L("Veja as recomendações para itens que dependem de você.")).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(spacing: 8) {
                    if quick > 0 {
                        Button {
                            Task { await model.quickClean() }
                        } label: {
                            Label(L("Limpar %@", Fmt.size(quick)), systemImage: "sparkles").frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .help(L("Limpa só o que está marcado como seguro e não pede senha"))
                    }
                    Button(L("Ver detalhes")) { model.section = .recommendations }
                }
            }
        }
    }
}

struct CategoryGrid: View {
    @EnvironmentObject var model: AppModel
    let analysis: Analysis

    var body: some View {
        let items = analysis.categoryBytes.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let biggest = Double(items.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Por categoria")).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(items, id: \.key) { category, bytes in
                    Button {
                        model.focusedCategory = category
                        model.section = .categories
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: category.icon).foregroundStyle(category.color).frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(category.title).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.size(bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                SizeBar(fraction: Double(bytes) / biggest, color: category.color)
                            }
                        }
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
