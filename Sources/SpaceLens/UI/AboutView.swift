import SwiftUI

/// What SpaceLens is, which version you run, where the code lives and what it does and does not do with your data.
struct AboutView: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    private static let repository = "https://github.com/\(UpdateChecker.defaultRepository)"

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                card(title: L("O que é")) {
                    Text(
                        L(
                            "O SpaceLens é um app gratuito e de código aberto para macOS que mostra o que consome seu armazenamento, explica o que pode ser apagado e roda rotinas de limpeza. Ele vive na janela e na barra de menus."
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                card(title: L("O que ele promete")) {
                    VStack(alignment: .leading, spacing: 8) {
                        promise("checkmark.shield", L("Nada é apagado sem a sua confirmação."))
                        promise("trash", L("O que você escolhe à mão vai só para a Lixeira."))
                        promise(
                            "lock.shield",
                            L(
                                "Itens de sistema usam o diálogo de administrador do macOS: o SpaceLens nunca vê nem guarda sua senha."
                            ))
                        promise(
                            "hand.raised",
                            L("Sistema, chaves, iCloud, Mail e a biblioteca do Fotos são sempre recusados."))
                        promise(
                            "network.slash",
                            L(
                                "Nenhum dado seu sai do Mac. A única conexão é a verificação de atualização, que você pode desligar."
                            ))
                    }
                }
                card(title: L("Versão")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            updateStatus
                            Spacer()
                            if model.availableUpdate != nil {
                                Button(L("Baixar")) { model.openUpdate(download: true) }.buttonStyle(.borderedProminent)
                                Button(L("Ver novidades")) { model.openUpdate(download: false) }
                            } else {
                                Button(L("Verificar agora")) { Task { await model.checkForUpdates() } }
                                    .disabled(model.updateStatus == .checking)
                            }
                        }
                        Divider()
                        info(
                            L("Sistema"),
                            "macOS \(Self.macOSVersion) · \(Self.architecture)")
                        info(L("Idioma"), model.settings.language.nativeName)
                        HStack {
                            info(L("Dados em"), "~/Library/Application Support/SpaceLens")
                            Spacer()
                            Button(L("Mostrar no Finder")) {
                                revealInFinder(JSONStore<Int>.directory().path)
                            }
                        }
                    }
                }
                card(title: L("Links")) {
                    HStack(spacing: 10) {
                        link(L("Código-fonte"), "chevron.left.forwardslash.chevron.right", Self.repository)
                        link(L("Notas das versões"), "doc.text", Self.repository + "/releases")
                        link(L("Reportar um problema"), "ladybug", Self.repository + "/issues/new/choose")
                        link(L("Licença MIT"), "scroll", Self.repository + "/blob/main/LICENSE")
                        Spacer()
                    }
                    HStack {
                        Button {
                            copyToPasteboard(diagnostics)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(
                                copied ? L("Copiado!") : L("Copiar informações para o suporte"),
                                systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Text(L("Versão, macOS e idioma. Nenhum arquivo seu."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L("Copyright © 2026 Everton Xavier. Distribuído sob a licença MIT."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(verbatim: "SpaceLens").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(L("Versão %@", version)).font(.title3).foregroundStyle(.secondary)
            Text(L("Veja o que ocupa o espaço do seu Mac e libere com segurança."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var updateStatus: some View {
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
                Label(L("Versão %@", version), systemImage: "info.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func link(_ title: String, _ icon: String, _ url: String) -> some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            Label(title, systemImage: icon)
        }
    }

    /// "27.0.1", not the system's localized "Versão 27.0.1 (Compilação …)".
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// For bug reports: no paths, no file names.
    private var diagnostics: String {
        """
        SpaceLens \(version)
        macOS \(Self.macOSVersion) (\(Self.architecture))
        Language: \(model.settings.language.rawValue) → \(Localizer.shared.effective.rawValue)
        Full Disk Access: \(model.fullDiskAccess ? "on" : "off")
        Menu bar item: \(model.settings.showMenuBarItem ? "on" : "off")
        """
    }
}
