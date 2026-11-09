import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView(
                "Sem histórico", systemImage: "list.bullet.rectangle",
                description: Text("Limpezas manuais e rotinas aparecem aqui, com quanto espaço liberaram."))
        } else {
            let total = model.history.reduce(Int64(0)) { $0 + $1.freed }
            List {
                Text("Total liberado de vez: **\(Fmt.size(total))**").listRowSeparator(.hidden)
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
                ToolbarItem { Button("Limpar histórico", role: .destructive) { model.clearHistory() } }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            SwiftUI.Section("Análise") {
                Picker("Analisar", selection: $model.settings.scope) {
                    ForEach(AppSettings.ScanScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Analisar sozinho", selection: $model.settings.autoScanHours) {
                    Text("Nunca").tag(0)
                    Text("A cada 6 horas").tag(6)
                    Text("A cada 12 horas").tag(12)
                    Text("Uma vez por dia").tag(24)
                    Text("Uma vez por semana").tag(168)
                }
                HStack {
                    Label(
                        model.fullDiskAccess ? "Acesso Total ao Disco: ligado" : "Acesso Total ao Disco: desligado",
                        systemImage: model.fullDiskAccess ? "checkmark.shield.fill" : "lock.shield"
                    )
                    .foregroundStyle(model.fullDiskAccess ? .green : .orange)
                    Spacer()
                    Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                }
                Text(
                    "Para ver Mail, Mensagens, Safari e Lixeira, adicione o SpaceLens em Privacidade e Segurança › Acesso Total ao Disco. O macOS pode pedir de novo após atualizar o app."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Segurança") {
                Toggle("Pedir Touch ID ou senha antes de limpar", isOn: $model.settings.requireAuthToClean)
                Text(
                    "Itens de sistema (como /Library/Caches) sempre pedem a senha de administrador ou a digital pelo próprio macOS. O SpaceLens nunca vê nem guarda sua senha."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Sempre mandar para a Lixeira, mesmo o que é seguro apagar", isOn: $model.settings.alwaysUseTrash)
            }
            SwiftUI.Section("Barra de menus") {
                Toggle("Mostrar espaço livre ao lado do ícone", isOn: $model.settings.showFreeSpaceInMenuBar)
                Stepper(
                    "Avisar em vermelho abaixo de \(model.settings.lowSpaceThresholdGB) GB livres",
                    value: $model.settings.lowSpaceThresholdGB, in: 1...500)
                Toggle(
                    "Abrir ao iniciar sessão",
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Enviar notificações das rotinas", isOn: $model.settings.notifications)
            }
            SwiftUI.Section("Sobre") {
                LabeledContent(
                    "Versão",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Dados em", value: "~/Library/Application Support/SpaceLens")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}
