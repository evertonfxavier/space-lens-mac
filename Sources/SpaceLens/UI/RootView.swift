import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Pane?>(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.title, systemImage: pane.icon)
                        .badge(badge(for: pane))
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                if !model.fullDiskAccess { FullDiskAccessBanner() }
                if model.analysisIsStale && !model.isScanning { StaleBanner() }
                if model.isScanning { ScanProgressBar() }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ScanToolbar() }
        }
        .navigationTitle(model.section.title)
        .sheet(item: $model.report) { ReportSheet(report: $0) }
        .overlay { if let message = model.busyMessage { BusyOverlay(message: message) } }
        .frame(minWidth: 940, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .recommendations: RecommendationsView()
        case .categories: CategoriesView()
        case .explorer: ExplorerView()
        case .duplicates: DuplicatesView()
        case .routines: RoutinesView()
        case .history: HistoryView()
        }
    }

    private func badge(for pane: Pane) -> Text? {
        switch pane {
        case .recommendations:
            let size = model.analysis?.safeFreeable ?? 0
            return size > 0 ? Text(Fmt.size(size)) : nil
        case .routines:
            let running = model.runningRoutines.count
            return running > 0 ? Text("\(running) rodando") : nil
        default: return nil
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let usage = model.usage {
            VStack(alignment: .leading, spacing: 6) {
                SizeBar(fraction: usage.usedFraction, color: model.isLowOnSpace ? .red : .accentColor)
                Text("\(Fmt.size(usage.availableImportant)) livres de \(Fmt.size(usage.total))")
                    .font(.caption).foregroundStyle(model.isLowOnSpace ? .red : .secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

struct ScanToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.isScanning {
                Button(role: .cancel) {
                    model.cancelScan()
                } label: {
                    Label("Cancelar", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label(model.analysis == nil ? "Analisar" : "Analisar de novo", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Analisar o disco (⌘R)")
            }
        }
    }
}

struct ScanProgressBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                switch model.phase {
                case .scanning(let items, let bytes, let path):
                    Text("Analisando… \(items.formatted()) itens · \(Fmt.size(bytes))").font(.callout.weight(.medium))
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .analyzing:
                    Text("Classificando o que pode ser apagado…").font(.callout.weight(.medium))
                case .idle: EmptyView()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.blue.opacity(0.08))
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Acesso Total ao Disco desligado").font(.callout.weight(.semibold))
                Text(
                    "Sem ele o macOS esconde Mail, Mensagens, Safari, Lixeira e outras áreas. O tamanho delas não entra na análise."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }
}

struct StaleBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            Text("Algo mudou desde a última análise. Analise de novo para atualizar os números e o Explorar.")
                .font(.callout)
            Spacer()
            Button("Analisar de novo") { model.startScan() }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }
}

struct BusyOverlay: View {
    var message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .ignoresSafeArea()
    }
}

struct ReportSheet: View {
    let report: CleaningReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = report.result
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(color)
                VStack(alignment: .leading) {
                    Text(report.title).font(.title3.weight(.semibold))
                    Text(headline).foregroundStyle(.secondary)
                }
            }
            if r.trashed > 0 {
                Label(
                    "\(Fmt.size(r.trashed)) foram para a Lixeira e só liberam espaço quando você esvaziá-la (recomendação “Esvaziar Lixeira”, depois de analisar de novo).",
                    systemImage: "trash"
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            if r.cancelled {
                Label("Você cancelou a autorização. Nada de sistema foi apagado.", systemImage: "hand.raised")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !r.failures.isEmpty {
                Text("Não foi possível (\(r.failures.count))").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(r.failures.prefix(12).enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 1) {
                                if !failure.path.isEmpty {
                                    Text(failure.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                }
                                Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
                if r.failures.contains(where: { $0.reason.contains("Acesso Total ao Disco") }) {
                    Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                }
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
    }

    private var ok: Bool { report.result.removedCount > 0 }
    private var icon: String {
        ok
            ? (report.result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            : "xmark.octagon.fill"
    }
    private var color: Color { ok ? (report.result.failures.isEmpty ? .green : .orange) : .red }
    private var headline: String {
        let r = report.result
        if r.freed > 0 { return "Liberou \(Fmt.size(r.freed)) em \(r.removedCount) item(ns)." }
        if r.trashed > 0 { return "Moveu \(r.removedCount) item(ns) para a Lixeira." }
        if r.removedCount > 0 { return "\(r.removedCount) item(ns) removido(s)." }
        return "Nada foi removido."
    }
}
