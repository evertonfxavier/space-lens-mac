import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView(
                L("Sem histórico"), systemImage: "list.bullet.rectangle",
                description: Text(L("Limpezas manuais e rotinas aparecem aqui, com quanto espaço liberaram.")))
        } else {
            let total = model.history.reduce(Int64(0)) { $0 + $1.freed }
            List {
                Text(LocalizedStringKey(L("Total liberado de vez: **%@**", Fmt.size(total)))).listRowSeparator(.hidden)
                ForEach(model.history) { record in
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: record.failed
                                ? "xmark.octagon.fill" : (record.routineID == nil ? "hand.tap.fill" : "clock.fill")
                        )
                        .foregroundStyle(record.failed ? .red : (record.routineID == nil ? Color.accentColor : .green))
                        .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.routineName).font(.headline)
                            Text(record.message).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.dateTimeString(record.date)).font(.caption).foregroundStyle(.secondary)
                            if record.freed > 0 {
                                Text(Fmt.size(record.freed)).monospacedDigit().foregroundStyle(.green)
                            }
                        }
                    }.padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .toolbar {
                ToolbarItem { Button(L("Limpar histórico"), role: .destructive) { model.clearHistory() } }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            SwiftUI.Section(L("Idioma")) {
                Picker(L("Idioma do aplicativo"), selection: $model.settings.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
                }
                Text(
                    L(
                        "Vale na hora para o app. Os diálogos do macOS (como a senha de administrador) mudam na próxima vez que você abrir o SpaceLens."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section(L("Análise")) {
                Picker(L("Analisar"), selection: $model.settings.scope) {
                    ForEach(AppSettings.ScanScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L("Analisar sozinho"), selection: $model.settings.autoScanHours) {
                    Text(L("Nunca")).tag(0)
                    Text(L("A cada 6 horas")).tag(6)
                    Text(L("A cada 12 horas")).tag(12)
                    Text(L("Uma vez por dia")).tag(24)
                    Text(L("Uma vez por semana")).tag(168)
                }
                HStack {
                    Label(
                        model.fullDiskAccess
                            ? L("Acesso Total ao Disco: ligado") : L("Acesso Total ao Disco: desligado"),
                        systemImage: model.fullDiskAccess ? "checkmark.shield.fill" : "lock.shield"
                    )
                    .foregroundStyle(model.fullDiskAccess ? .green : .orange)
                    Spacer()
                    Button(L("Abrir Ajustes do Sistema")) { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                }
                Text(
                    L(
                        "Para ver Mail, Mensagens, Safari e Lixeira, adicione o SpaceLens em Privacidade e Segurança › Acesso Total ao Disco. O macOS pode pedir de novo após atualizar o app."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section(L("Segurança")) {
                Toggle(L("Pedir Touch ID ou senha antes de limpar"), isOn: $model.settings.requireAuthToClean)
                Text(
                    L(
                        "Itens de sistema (como /Library/Caches) sempre pedem a senha de administrador ou a digital pelo próprio macOS. O SpaceLens nunca vê nem guarda sua senha."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    L("Sempre mandar para a Lixeira, mesmo o que é seguro apagar"), isOn: $model.settings.alwaysUseTrash
                )
            }
            SwiftUI.Section(L("Barra de menus")) {
                Toggle(L("Mostrar o SpaceLens na barra de menus"), isOn: $model.settings.showMenuBarItem)
                if !model.settings.showMenuBarItem {
                    Text(L("Sem o ícone e o painel da barra de menus, o SpaceLens fica no Dock."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L("Mostrar espaço livre ao lado do ícone"), isOn: $model.settings.showFreeSpaceInMenuBar)
                    .disabled(!model.settings.showMenuBarItem)
                Stepper(
                    L("Avisar em vermelho abaixo de %lld GB livres", model.settings.lowSpaceThresholdGB),
                    value: $model.settings.lowSpaceThresholdGB, in: 1...500)
                Toggle(
                    L("Abrir ao iniciar sessão"),
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle(L("Enviar notificações das rotinas"), isOn: $model.settings.notifications)
            }
            SwiftUI.Section(L("Atualizações")) {
                Toggle(L("Avisar quando houver uma versão nova no GitHub"), isOn: $model.settings.checkForUpdates)
                HStack {
                    updateStatusLabel
                    Spacer()
                    Button(L("Verificar agora")) { Task { await model.checkForUpdates() } }
                        .disabled(model.updateStatus == .checking)
                }
                Text(
                    L(
                        "O SpaceLens consulta uma vez por dia a página pública de releases do GitHub. Nenhum dado seu é enviado."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var updateStatusLabel: some View {
        if let update = model.availableUpdate {
            Label(L("Nova versão disponível: %@", update.version.description), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        } else {
            switch model.updateStatus {
            case .checking: Label(L("Verificando…"), systemImage: "arrow.triangle.2.circlepath")
            case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .upToDate:
                Label(L("Você está na versão mais recente."), systemImage: "checkmark.circle").foregroundStyle(.green)
            case .idle:
                if let date = model.settings.lastUpdateCheck {
                    Label(L("Última verificação: %@", Fmt.ago(date)), systemImage: "clock").foregroundStyle(.secondary)
                } else {
                    Label(L("Ainda não verificado."), systemImage: "clock").foregroundStyle(.secondary)
                }
            }
        }
    }
}
