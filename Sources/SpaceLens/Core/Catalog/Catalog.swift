import Foundation

/// One thing SpaceLens knows about: where it lives, whether it can go and what happens if it does.
public struct CatalogEntry: Sendable {
    public enum Match: Sendable {
        /// The node at exactly this path.
        case path(String)
        /// Every direct child of the directory at this path.
        case childrenOf(String)
    }

    public enum Scope: Sendable {
        /// The match owns the whole subtree: its size counts once and nothing below is looked at.
        case whole
        /// The match only labels the subtree; deeper rules may still override it.
        case inherit
    }

    public var id: String
    public var title: String
    public var category: Category
    public var safety: Safety
    public var explanation: String
    public var consequence: String
    public var matches: [Match]
    public var scope: Scope
    /// Shows up as something you can clean. Entries that only label stay non-actionable.
    public var actionable: Bool
    public var mode: RemovalMode
    public var command: CommandSpec?
    public var admin: Bool
    public var preselect: Bool
    public var minItemSize: Int64
    /// For `childrenOf` matches: which children belong to this entry.
    public var childFilter: (@Sendable (FileNode, Date) -> Bool)?

    public init(
        id: String, title: String, category: Category, safety: Safety, explanation: String, consequence: String = "",
        matches: [Match], scope: Scope = .whole, actionable: Bool = false, mode: RemovalMode = .delete,
        command: CommandSpec? = nil, admin: Bool = false, preselect: Bool? = nil, minItemSize: Int64 = 1 << 20,
        childFilter: (@Sendable (FileNode, Date) -> Bool)? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.safety = safety
        self.explanation = explanation
        self.consequence = consequence
        self.matches = matches
        self.scope = scope
        self.actionable = actionable
        self.mode = mode
        self.command = command
        self.admin = admin
        self.preselect = preselect ?? (safety == .safe && !admin)
        self.minItemSize = minItemSize
        self.childFilter = childFilter
    }

    var nodeClass: NodeClass {
        NodeClass(
            category: category, safety: safety, title: title, explanation: explanation,
            consequence: consequence.isEmpty ? nil : consequence, entryID: id)
    }
}

/// A folder a build tool recreates, recognised by its name plus a file that proves it belongs to a project.
public struct ArtifactKind: Sendable {
    public var dirName: String
    /// Files next to the folder. A marker like `*.csproj` matches by suffix.
    public var siblingMarkers: [String]
    /// Files inside the folder.
    public var insideMarkers: [String]
    public var group: String
}

public struct ArtifactGroup: Sendable {
    public var id: String
    public var title: String
    public var explanation: String
    public var consequence: String
}

public enum Catalog {
    static let inactiveDays = 30

    public static func entries(home h: String) -> [CatalogEntry] {
        func inHome(_ rel: String) -> String { h + "/" + rel }
        let day: TimeInterval = 86_400
        let installers: Set<String> = ["dmg", "pkg", "iso", "xip", "ipsw"]

        var list: [CatalogEntry] = []

        // MARK: Sistema (nunca tocar)
        list.append(
            CatalogEntry(
                id: "system.core", title: L("Sistema macOS"), category: .system, safety: .keep,
                explanation: L("Arquivos do macOS. Apagar qualquer coisa aqui pode impedir o Mac de iniciar."),
                matches: [
                    "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db", "/private/var/vm",
                    "/cores", "/Library",
                ]
                .map { .path($0) }, scope: .inherit))
        list.append(
            CatalogEntry(
                id: "system.temp", title: L("Temporários do sistema"), category: .system, safety: .keep,
                explanation: L("Pastas temporárias por usuário. O macOS limpa sozinho ao reiniciar."),
                matches: [.path("/private/var/folders")], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "system.admin.caches", title: L("Caches do sistema (/Library/Caches)"), category: .caches,
                safety: .safe,
                explanation: L(
                    "Caches que apps e o macOS guardam para todos os usuários. São recriados quando preciso."),
                consequence: L("Pede sua senha ou digital. Apps podem demorar um pouco mais na próxima abertura."),
                matches: [.childrenOf("/Library/Caches")], actionable: true, admin: true))
        list.append(
            CatalogEntry(
                id: "system.admin.logs", title: L("Logs do sistema"), category: .caches, safety: .safe,
                explanation: L("Registros de funcionamento do macOS e de apps. Servem só para diagnosticar problemas."),
                consequence: L("Pede sua senha ou digital. O histórico de diagnóstico some; nada seu é perdido."),
                matches: [.childrenOf("/Library/Logs"), .childrenOf("/private/var/log")], actionable: true,
                admin: true))
        list.append(
            CatalogEntry(
                id: "system.admin.updates", title: L("Atualizações baixadas"), category: .system, safety: .safe,
                explanation: L("Instaladores de atualização que o macOS já baixou e não usa mais."),
                consequence: L("Pede sua senha ou digital. O macOS baixa de novo se precisar."),
                matches: [.childrenOf("/Library/Updates")], actionable: true, admin: true))

        // MARK: Caches e logs do usuário
        list.append(
            CatalogEntry(
                id: "caches.dir", title: L("Caches e logs"), category: .caches, safety: .safe,
                explanation: L("Pastas de arquivos temporários de apps."),
                matches: [.path(inHome("Library/Caches")), .path(inHome("Library/Logs")), .path(inHome(".cache"))],
                scope: .inherit))
        list.append(
            CatalogEntry(
                id: "caches.user", title: L("Caches de apps"), category: .caches, safety: .safe,
                explanation:
                    L("Arquivos temporários que cada app guarda para abrir mais rápido. Os apps recriam sozinhos."),
                consequence: L("Na primeira abertura o app pode ficar um pouco mais lento. Nada seu é perdido."),
                matches: [.childrenOf(inHome("Library/Caches")), .childrenOf(inHome(".cache"))], actionable: true,
                childFilter: { node, _ in !node.name.hasPrefix("com.apple.") }))
        list.append(
            CatalogEntry(
                id: "caches.apple", title: L("Caches de apps da Apple"), category: .caches, safety: .review,
                explanation:
                    L(
                        "Caches do Safari, Fotos, iCloud e outros apps da Apple. O macOS recria, mas alguns demoram para ressincronizar."
                    ),
                consequence: L("Fotos, iCloud e Safari podem refazer índices e baixar miniaturas de novo."),
                matches: [.childrenOf(inHome("Library/Caches"))], actionable: true,
                childFilter: { node, _ in node.name.hasPrefix("com.apple.") }))
        list.append(
            CatalogEntry(
                id: "caches.logs", title: L("Logs de apps"), category: .caches, safety: .safe,
                explanation: L(
                    "Registros de funcionamento e relatórios de erro. Servem só para diagnosticar problemas."),
                consequence: L("O histórico de diagnóstico some. Nada seu é perdido."),
                matches: [
                    .childrenOf(inHome("Library/Logs")), .path(inHome("Library/Application Support/CrashReporter")),
                ], actionable: true))
        list.append(
            CatalogEntry(
                id: "caches.appinternal", title: L("Caches internos de apps (VS Code, Slack, Discord, Chrome)"),
                category: .caches, safety: .safe,
                explanation:
                    L("Caches que esses apps guardam dentro dos próprios dados. Podem ser grandes e são recriados."),
                consequence:
                    L("Feche o app antes. Ele reconstrói o cache na próxima abertura. Seus dados e logins ficam."),
                matches: [
                    "Library/Application Support/Code/Cache", "Library/Application Support/Code/CachedData",
                    "Library/Application Support/Code/CachedExtensionVSIXs", "Library/Application Support/Code/logs",
                    "Library/Application Support/Code/Code Cache", "Library/Application Support/Slack/Cache",
                    "Library/Application Support/Slack/Code Cache",
                    "Library/Application Support/Slack/Service Worker/CacheStorage",
                    "Library/Application Support/discord/Cache", "Library/Application Support/discord/Code Cache",
                    "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
                ].map { .path(inHome($0)) }, actionable: true))

        // MARK: Lixeira
        list.append(
            CatalogEntry(
                id: "trash.dir", title: L("Lixeira"), category: .trash, safety: .safe,
                explanation: L("Itens que você já mandou para a Lixeira. Continuam ocupando espaço até esvaziar."),
                matches: [.path(inHome(".Trash"))], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "trash.items", title: L("Esvaziar Lixeira"), category: .trash, safety: .safe,
                explanation: L("Itens que você já mandou para a Lixeira. Continuam ocupando espaço até esvaziar."),
                consequence: L("Definitivo: depois de esvaziar não dá para recuperar."),
                matches: [.childrenOf(inHome(".Trash"))], actionable: true, minItemSize: 0))

        // MARK: Downloads
        list.append(
            CatalogEntry(
                id: "downloads.dir", title: L("Downloads"), category: .downloads, safety: .review,
                explanation: L("Arquivos que você baixou. Só você sabe quais ainda importam."),
                matches: [.path(inHome("Downloads"))], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "downloads.installers", title: L("Instaladores em Downloads"), category: .downloads,
                safety: .review,
                explanation:
                    L("Arquivos .dmg, .pkg, .iso e .xip. Depois de instalar o app, o instalador só ocupa espaço."),
                consequence: L("Vão para a Lixeira. Se precisar instalar de novo, baixe outra vez."),
                matches: [.childrenOf(inHome("Downloads"))], actionable: true, mode: .trash,
                childFilter: { node, _ in installers.contains((node.name as NSString).pathExtension.lowercased()) }))
        list.append(
            CatalogEntry(
                id: "downloads.old", title: L("Downloads antigos (90+ dias)"), category: .downloads, safety: .review,
                explanation: L("Itens baixados há mais de 3 meses e nunca mexidos desde então."),
                consequence: L("Vão para a Lixeira, de onde você pode recuperar."),
                matches: [.childrenOf(inHome("Downloads"))], actionable: true, mode: .trash,
                childFilter: { node, now in
                    guard let modified = node.modified else { return false }
                    return now.timeIntervalSince(modified) > 90 * day
                }))

        // MARK: Mídia, documentos, nuvem, mensagens
        list.append(
            CatalogEntry(
                id: "media.library", title: L("Biblioteca do app Fotos"), category: .media, safety: .keep,
                explanation: L(
                    "Todas as suas fotos e vídeos do app Fotos. Não é seguro mexer na pasta por fora do app."),
                consequence: L("Para liberar espaço, use Fotos › Ajustes › iCloud › Otimizar Armazenamento do Mac."),
                matches: [.childrenOf(inHome("Pictures"))],
                childFilter: { node, _ in node.name.hasSuffix(".photoslibrary") }
            ))
        list.append(
            CatalogEntry(
                id: "media.folders", title: L("Fotos, vídeos e músicas"), category: .media, safety: .review,
                explanation:
                    L(
                        "Suas mídias pessoais. O SpaceLens não decide por você: use o Explorar para ver os maiores itens."
                    ),
                matches: [.path(inHome("Movies")), .path(inHome("Music")), .path(inHome("Pictures"))], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "documents.folders", title: L("Documentos e Mesa"), category: .documents, safety: .review,
                explanation:
                    L("Seus documentos. O SpaceLens não decide por você: use o Explorar para ver os maiores itens."),
                matches: [.path(inHome("Documents")), .path(inHome("Desktop"))], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "cloud.sync", title: L("Pastas sincronizadas na nuvem"), category: .cloud, safety: .keep,
                explanation:
                    L("iCloud Drive e provedores de nuvem. Apagar aqui apaga também na nuvem e nos outros aparelhos."),
                consequence: L("Para liberar espaço local, use “Remover Download” no Finder."),
                matches: [.path(inHome("Library/Mobile Documents")), .path(inHome("Library/CloudStorage"))]))
        list.append(
            CatalogEntry(
                id: "messages.attachments", title: L("Anexos do Mensagens"), category: .messages, safety: .review,
                explanation: L("Fotos, vídeos e arquivos que você recebeu no app Mensagens."),
                consequence: L("Vão para a Lixeira. As conversas ficam, mas os anexos deixam de abrir."),
                matches: [.path(inHome("Library/Messages/Attachments"))], actionable: true, mode: .trash))
        list.append(
            CatalogEntry(
                id: "messages.store", title: L("Mensagens e E-mail"), category: .messages, safety: .keep,
                explanation: L("Suas conversas e e-mails guardados neste Mac."),
                matches: [
                    .path(inHome("Library/Mail")), .path(inHome("Library/Containers/com.apple.mail")),
                    .path(inHome("Library/Messages")),
                ], scope: .inherit))

        // MARK: Backups
        list.append(
            CatalogEntry(
                id: "backups.dir", title: L("Backups de iPhone e iPad"), category: .backups, safety: .review,
                explanation: L("Pasta dos backups de aparelhos feitos pelo Finder."),
                matches: [.path(inHome("Library/Application Support/MobileSync/Backup"))], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "backups.ios", title: L("Backups de iPhone e iPad"), category: .backups, safety: .review,
                explanation: L("Cópia completa de um aparelho feita pelo Finder. Cada pasta é um aparelho."),
                consequence: L("Vão para a Lixeira. Sem o backup você só restaura o aparelho pelo iCloud, se houver."),
                matches: [.childrenOf(inHome("Library/Application Support/MobileSync/Backup"))], actionable: true,
                mode: .trash))

        // MARK: Aplicativos
        list.append(
            CatalogEntry(
                id: "apps.list", title: L("Aplicativo"), category: .apps, safety: .review,
                explanation:
                    L("App instalado. Apps que você não usa mais podem ser movidos para a Lixeira pelo Explorar."),
                matches: [.childrenOf("/Applications"), .childrenOf(inHome("Applications"))]))
        list.append(
            CatalogEntry(
                id: "apps.dir", title: L("Aplicativos"), category: .apps, safety: .review,
                explanation: L("Apps instalados neste Mac."),
                matches: [.path("/Applications"), .path(inHome("Applications"))],
                scope: .inherit))

        // MARK: Máquinas virtuais e Docker
        list.append(
            CatalogEntry(
                id: "virt.docker", title: L("Docker Desktop"), category: .virtualization, safety: .review,
                explanation:
                    L(
                        "Disco virtual do Docker com imagens, contêineres e volumes. O arquivo só cresce; apagar imagens sem uso não o encolhe sozinho."
                    ),
                consequence:
                    L(
                        "Roda “docker system prune”: remove contêineres parados, redes e imagens sem uso. Volumes ficam."
                    ),
                matches: [.path(inHome("Library/Containers/com.docker.docker"))],
                actionable: true, command: CommandSpec(tool: "docker", args: ["system", "prune", "-f"]),
                preselect: false, minItemSize: 100 << 20))
        list.append(
            CatalogEntry(
                id: "virt.vms", title: L("Máquinas virtuais"), category: .virtualization, safety: .review,
                explanation:
                    L("Discos de máquinas virtuais (Parallels, VMware, UTM, Colima). Cada uma pode ter dezenas de GB."),
                consequence: L("Apagar uma máquina virtual apaga tudo que estiver dentro dela."),
                matches: [
                    .path(inHome("Parallels")), .path(inHome("Virtual Machines.localized")),
                    .path(inHome("Library/Containers/com.utmapp.UTM")), .path(inHome(".colima")),
                    .path(inHome(".lima")),
                ]))

        // MARK: Desenvolvimento
        list.append(
            CatalogEntry(
                id: "dev.xcode.derived", title: L("Xcode: DerivedData"), category: .developer, safety: .safe,
                explanation:
                    L("Resultados de compilação e índices do Xcode. É a primeira coisa a apagar quando o Xcode pesa."),
                consequence: L("O próximo build de cada projeto será completo e mais demorado."),
                matches: [.path(inHome("Library/Developer/Xcode/DerivedData"))], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.xcode.devicesupport", title: L("Xcode: símbolos de dispositivos"), category: .developer,
                safety: .safe,
                explanation: L("Arquivos de depuração de cada versão de iOS/watchOS/tvOS que você já conectou."),
                consequence: L("O Xcode baixa de novo, do aparelho, na próxima vez que ele for conectado."),
                matches: [
                    .childrenOf(inHome("Library/Developer/Xcode/iOS DeviceSupport")),
                    .childrenOf(inHome("Library/Developer/Xcode/watchOS DeviceSupport")),
                    .childrenOf(inHome("Library/Developer/Xcode/tvOS DeviceSupport")),
                ], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.xcode.archives", title: L("Xcode: Archives"), category: .developer, safety: .review,
                explanation:
                    L(
                        "Builds arquivados para publicar. Guardam os símbolos (dSYM) usados para ler relatórios de crash."
                    ),
                consequence: L("Vão para a Lixeira. Sem o archive, crashes dessa versão ficam sem símbolos."),
                matches: [.path(inHome("Library/Developer/Xcode/Archives"))], actionable: true, mode: .trash))
        list.append(
            CatalogEntry(
                id: "dev.simulators", title: L("Simuladores do Xcode"), category: .developer, safety: .review,
                explanation:
                    L("Cada simulador de iPhone/iPad guarda um sistema inteiro. Os de versões antigas ficam órfãos."),
                consequence: L("Roda “xcrun simctl delete unavailable”: remove só simuladores que não funcionam mais."),
                matches: [.path(inHome("Library/Developer/CoreSimulator/Devices"))], actionable: true,
                command: CommandSpec(tool: "xcrun", args: ["simctl", "delete", "unavailable"]), preselect: false,
                minItemSize: 100 << 20))
        list.append(
            CatalogEntry(
                id: "dev.library", title: L("Ferramentas de desenvolvimento"), category: .developer, safety: .review,
                explanation: L("Dados do Xcode e simuladores."), matches: [.path(inHome("Library/Developer"))],
                scope: .inherit)
        )
        list.append(
            CatalogEntry(
                id: "dev.jspkg", title: L("Cache de pacotes JavaScript (npm, yarn, pnpm)"), category: .developer,
                safety: .safe,
                explanation: L("Pacotes baixados que o npm, yarn e pnpm guardam para instalar mais rápido."),
                consequence:
                    L("A próxima instalação baixa os pacotes de novo. Projetos já instalados continuam funcionando."),
                matches: [
                    .path(inHome(".npm/_cacache")), .path(inHome(".npm/_logs")), .path(inHome(".yarn/cache")),
                    .path(inHome(".yarn/berry/cache")), .path(inHome("Library/pnpm/store")),
                    .path(inHome(".pnpm-store")),
                    .path(inHome(".local/share/pnpm/store")),
                ], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.cargo", title: L("Cache do Cargo (Rust)"), category: .developer, safety: .safe,
                explanation: L("Código-fonte de dependências Rust baixadas."),
                consequence: L("O próximo cargo build baixa de novo o que precisar."),
                matches: [.path(inHome(".cargo/registry")), .path(inHome(".cargo/git"))], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.gradle", title: L("Cache do Gradle"), category: .developer, safety: .safe,
                explanation: L("Dependências e distribuições do Gradle baixadas."),
                consequence: L("O próximo build baixa de novo, o que pode demorar."),
                matches: [.path(inHome(".gradle/caches")), .path(inHome(".gradle/wrapper/dists"))], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.maven", title: L("Repositório local do Maven"), category: .developer, safety: .review,
                explanation:
                    L("Dependências Maven baixadas. Também guarda o que você instalou localmente com “mvn install”."),
                consequence:
                    L("Dependências públicas são baixadas de novo; artefatos instalados só localmente se perdem."),
                matches: [.path(inHome(".m2/repository"))], actionable: true, mode: .trash))
        list.append(
            CatalogEntry(
                id: "dev.nuget", title: L("Pacotes NuGet (.NET)"), category: .developer, safety: .safe,
                explanation: L("Pacotes .NET baixados na restauração dos projetos."),
                consequence: L("O próximo dotnet restore baixa de novo o que precisar."),
                matches: [.path(inHome(".nuget/packages"))], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.go", title: L("Módulos do Go"), category: .developer, safety: .safe,
                explanation: L("Dependências Go baixadas."), consequence: L("O próximo go build baixa de novo."),
                matches: [.path(inHome("go/pkg/mod"))], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.conda", title: L("Pacotes do Conda"), category: .developer, safety: .safe,
                explanation: L("Pacotes Python baixados pelo Conda."),
                consequence: L("Ambientes existentes continuam; novos baixam de novo."),
                matches: [.path(inHome(".conda/pkgs"))], actionable: true))
        list.append(
            CatalogEntry(
                id: "dev.runtimes", title: L("Versões de linguagens instaladas"), category: .developer, safety: .review,
                explanation:
                    L(
                        "Versões de Node, Python, Ruby, Rust e Java instaladas por nvm, pyenv, rbenv, rustup e sdkman. Versões antigas costumam ficar esquecidas."
                    ),
                consequence: L("Vão para a Lixeira. Projetos que usam aquela versão vão pedir para instalar de novo."),
                matches: [
                    .childrenOf(inHome(".nvm/versions/node")), .childrenOf(inHome(".pyenv/versions")),
                    .childrenOf(inHome(".rbenv/versions")), .childrenOf(inHome(".rustup/toolchains")),
                    .childrenOf(inHome(".sdkman/candidates/java")),
                ], actionable: true, mode: .trash))
        list.append(
            CatalogEntry(
                id: "dev.tools", title: L("Ferramentas de desenvolvimento"), category: .developer, safety: .keep,
                explanation: L(
                    "SDKs, gerenciadores de pacote e configuração de ferramentas. Apagar quebra seu ambiente."),
                matches: [
                    .path("/opt/homebrew"), .path("/usr/local"), .path(inHome(".dotnet")), .path(inHome(".aspnet")),
                    .path(inHome("Library/Android/sdk")), .path(inHome(".docker")), .path(inHome(".vscode")),
                    .path(inHome(".nvm")), .path(inHome(".pyenv")), .path(inHome(".cargo")), .path(inHome(".rustup")),
                ], scope: .inherit))

        // MARK: Dados de apps (por último: regras mais gerais)
        list.append(
            CatalogEntry(
                id: "appdata.library", title: L("Dados de apps e do macOS"), category: .appData, safety: .review,
                explanation: L("Configurações, bancos de dados e arquivos que os apps guardam na sua Biblioteca."),
                matches: [.path(inHome("Library"))], scope: .inherit))
        list.append(
            CatalogEntry(
                id: "appdata.app", title: L("Dados do app"), category: .appData, safety: .review,
                explanation:
                    L(
                        "Configurações, logins e dados que o app guarda. Pode incluir coisas que não existem em outro lugar."
                    ),
                consequence: L("Apagar pode desconectar contas ou perder o que só existia aqui."),
                matches: [
                    .childrenOf(inHome("Library/Application Support")), .childrenOf(inHome("Library/Containers")),
                    .childrenOf(inHome("Library/Group Containers")),
                ], scope: .inherit))

        return list
    }

    // MARK: - Artefatos de projeto

    /// Title, explanation and consequence of everything that can show up as a recommendation, by id.
    public static func texts(home: String) -> [String: (title: String, explanation: String, consequence: String)] {
        var map: [String: (title: String, explanation: String, consequence: String)] = [:]
        for entry in entries(home: home) { map[entry.id] = (entry.title, entry.explanation, entry.consequence) }
        for group in artifactGroups.values { map[group.id] = (group.title, group.explanation, group.consequence) }
        map["large.old"] = Analyzer.largeOldText
        map["snapshots.tm"] = TimeMachineSnapshots.text
        return map
    }

    public static var artifactGroups: [String: ArtifactGroup] { groups }

    private static var groups: [String: ArtifactGroup] {
        [
            "node": ArtifactGroup(
                id: "artifact.node", title: L("node_modules de projetos"),
                explanation:
                    L(
                        "Dependências JavaScript instaladas dentro de cada projeto. Costumam ser o maior consumo de quem programa."
                    ),
                consequence: L("Rode npm/pnpm/yarn install no projeto para recriar.")),
            "rust": ArtifactGroup(
                id: "artifact.rust", title: L("Builds de Rust e Maven (target)"),
                explanation: L("Resultado de compilação dentro do projeto."),
                consequence: L("O próximo cargo build / mvn package recompila tudo.")),
            "swift": ArtifactGroup(
                id: "artifact.swift", title: L("Builds de Swift (.build)"),
                explanation: L("Resultado de compilação do Swift Package Manager."),
                consequence: L("O próximo swift build recompila tudo.")),
            "pods": ArtifactGroup(
                id: "artifact.pods", title: L("CocoaPods (Pods)"),
                explanation: L("Dependências iOS baixadas dentro do projeto."),
                consequence: L("Rode pod install para recriar.")),
            "gradle": ArtifactGroup(
                id: "artifact.gradle", title: L("Builds de Gradle (build, .gradle)"),
                explanation: L("Resultado de compilação e cache do Gradle dentro do projeto."),
                consequence: L("O próximo build recompila tudo.")),
            "dotnet": ArtifactGroup(
                id: "artifact.dotnet", title: L("Builds de .NET (bin e obj)"),
                explanation: L("Binários e arquivos intermediários gerados ao compilar projetos C#/F#."),
                consequence: L("O próximo dotnet build recompila tudo.")),
            "python": ArtifactGroup(
                id: "artifact.python", title: L("Ambientes virtuais Python (.venv)"),
                explanation: L("Cópia das bibliotecas Python de cada projeto."),
                consequence: L("Recrie com python -m venv e instale os requisitos de novo.")),
            "web": ArtifactGroup(
                id: "artifact.web", title: L("Caches de frameworks web (.next, .nuxt, .angular…)"),
                explanation: L(
                    "Resultado de build e cache de Next.js, Nuxt, Angular, Turbo e Parcel dentro do projeto."),
                consequence: L("O próximo build ou dev server recria.")),
            "terraform": ArtifactGroup(
                id: "artifact.terraform", title: L("Provedores do Terraform (.terraform)"),
                explanation: L("Plugins baixados pelo terraform init."),
                consequence: L("Rode terraform init para baixar de novo.")),
        ]
    }

    public static let artifactKinds: [ArtifactKind] = [
        ArtifactKind(dirName: "node_modules", siblingMarkers: ["package.json"], insideMarkers: [], group: "node"),
        ArtifactKind(dirName: "target", siblingMarkers: ["Cargo.toml", "pom.xml"], insideMarkers: [], group: "rust"),
        ArtifactKind(dirName: ".build", siblingMarkers: ["Package.swift"], insideMarkers: [], group: "swift"),
        ArtifactKind(dirName: "Pods", siblingMarkers: ["Podfile"], insideMarkers: [], group: "pods"),
        ArtifactKind(
            dirName: "build",
            siblingMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
            insideMarkers: [], group: "gradle"),
        ArtifactKind(
            dirName: ".gradle",
            siblingMarkers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
            insideMarkers: [], group: "gradle"),
        ArtifactKind(
            dirName: "bin", siblingMarkers: ["*.csproj", "*.fsproj", "*.vbproj"], insideMarkers: [], group: "dotnet"),
        ArtifactKind(
            dirName: "obj", siblingMarkers: ["*.csproj", "*.fsproj", "*.vbproj"], insideMarkers: [], group: "dotnet"),
        ArtifactKind(dirName: ".venv", siblingMarkers: [], insideMarkers: ["pyvenv.cfg"], group: "python"),
        ArtifactKind(dirName: "venv", siblingMarkers: [], insideMarkers: ["pyvenv.cfg"], group: "python"),
        ArtifactKind(dirName: ".next", siblingMarkers: ["package.json"], insideMarkers: [], group: "web"),
        ArtifactKind(dirName: ".nuxt", siblingMarkers: ["package.json"], insideMarkers: [], group: "web"),
        ArtifactKind(dirName: ".angular", siblingMarkers: ["angular.json"], insideMarkers: [], group: "web"),
        ArtifactKind(dirName: ".turbo", siblingMarkers: ["package.json"], insideMarkers: [], group: "web"),
        ArtifactKind(dirName: ".parcel-cache", siblingMarkers: ["package.json"], insideMarkers: [], group: "web"),
        ArtifactKind(dirName: ".terraform", siblingMarkers: ["*.tf"], insideMarkers: [], group: "terraform"),
    ]
}
