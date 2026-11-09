import SwiftUI

/// The popover that opens from the menu bar icon: how much room is left, what can go, and one-click actions.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    var openMain: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isScanning { scanning }
            freeable
            if !topItems.isEmpty { top }
            routines
            Divider()
            actions
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 9)
                Circle().trim(from: 0, to: model.usage?.usedFraction ?? 0)
                    .stroke(
                        model.isLowOnSpace ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: model.isLowOnSpace ? "exclamationmark.triangle.fill" : "internaldrive")
                    .font(.title3).foregroundStyle(model.isLowOnSpace ? .red : .secondary)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.freeSpaceText).font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.isLowOnSpace ? .red : .primary)
                Text(model.usage.map { "livres de \(Fmt.size($0.total))" } ?? "").font(.callout).foregroundStyle(
                    .secondary)
                if model.isLowOnSpace {
                    Text("Pouco espaço: abaixo de \(model.settings.lowSpaceThresholdGB) GB").font(
                        .caption.weight(.medium)
                    ).foregroundStyle(.red)
                }
            }
            Spacer()
        }
    }

    private var scanning: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            switch model.phase {
            case .scanning(let items, let bytes, _):
                Text("Analisando… \(items.formatted()) itens · \(Fmt.size(bytes))").font(.caption)
            default: Text("Classificando…").font(.caption)
            }
            Spacer()
            Button("Cancelar") { model.cancelScan() }.buttonStyle(.link).font(.caption)
        }
    }

    private var safeToFree: Int64 { model.analysis?.safeFreeable ?? model.summary?.safeFreeable ?? 0 }

    private var freeable: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.analysis != nil || model.summary != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    Text(
                        safeToFree > 0
                            ? "\(Fmt.size(safeToFree)) para liberar com segurança" : "Nada seguro para limpar agora"
                    )
                    .font(.callout.weight(.semibold))
                }
                if model.analysis != nil, model.quickCleanSize > 0 {
                    Button {
                        Task { await model.quickClean() }
                    } label: {
                        Label("Limpar \(Fmt.size(model.quickCleanSize))", systemImage: "sparkles").frame(
                            maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
                } else if model.analysis == nil, !model.isScanning {
                    Text("Analise de novo para poder limpar daqui.").font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.isScanning {
                Text("Ainda não analisei o disco. Analise para ver o que dá para apagar.").font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var topItems: [ScanSummary.Item] {
        if let analysis = model.analysis {
            return analysis.recommendations.filter { $0.safety == .safe && !$0.needsAdmin && !$0.sizeIsReference }
                .prefix(3)
                .map { .init(id: $0.id, title: $0.title, size: $0.totalSize, safety: $0.safety) }
        }
        return Array((model.summary?.top ?? []).prefix(3))
    }

    private var top: some View {
        VStack(spacing: 6) {
            ForEach(topItems, id: \.id) { item in
                HStack {
                    Text(item.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(Fmt.size(item.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var routines: some View {
        Group {
            if let (routine, date) = model.nextRoutine {
                Label("\(routine.name) · \(Fmt.ago(date))", systemImage: "clock").font(.caption).foregroundStyle(
                    .secondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                openMain()
            } label: {
                Label("Abrir", systemImage: "macwindow")
            }
            Button {
                model.startScan()
            } label: {
                Label("Analisar", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }.help("Ajustes")
            Button {
                quit()
            } label: {
                Image(systemName: "power")
            }.help("Sair do SpaceLens")
        }
        .buttonStyle(.borderless)
    }
}
