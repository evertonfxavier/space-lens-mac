import SwiftUI

struct ExplorerView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedPath: String?
    @State private var confirmTrash: FileNode?

    enum Mode: String, CaseIterable {
        case list
        case map

        var title: String { self == .list ? L("Lista") : L("Mapa") }
    }

    private var roots: [FileNode] { model.scan?.roots ?? [] }

    /// With several scan roots there is no single top folder, so a virtual "Este Mac" holds them.
    private var top: FileNode? {
        if roots.count == 1 { return roots[0] }
        guard !roots.isEmpty else { return nil }
        let virtual = FileNode(
            name: L("Este Mac"), path: "/", isDirectory: true, size: roots.reduce(0) { $0 + $1.size })
        virtual.children = roots.sorted { $0.size > $1.size }
        return virtual
    }

    private func node(at path: String?) -> FileNode? {
        guard let path else { return nil }
        for root in roots { if let hit = root.find(path: path) { return hit } }
        return nil
    }

    var body: some View {
        if let top {
            let current = node(at: model.explorerPath) ?? top
            VStack(spacing: 0) {
                toolbar(current: current, top: top)
                Divider()
                switch model.explorerMap ? Mode.map : Mode.list {
                case .list: ListPane(current: current, selectedPath: $selectedPath, open: open)
                case .map:
                    TreemapView(
                        node: current, selectedPath: selectedPath, classify: model.nodeClass,
                        onSelect: { selectedPath = $0.path }, onOpen: open)
                }
                Divider()
                Inspector(
                    node: node(at: selectedPath) ?? current, isSelection: selectedPath != nil,
                    onTrash: { confirmTrash = $0 })
            }
            .confirmationDialog(
                L("Mover “%@” para a Lixeira?", confirmTrash?.name ?? ""),
                isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
                titleVisibility: .visible, presenting: confirmTrash
            ) { target in
                Button(L("Mover %@ para a Lixeira", Fmt.size(target.size)), role: .destructive) {
                    Task {
                        await model.trashManually([target])
                        selectedPath = nil
                    }
                }
            } message: { _ in
                Text(L("Você pode recuperar pela Lixeira. O espaço só é liberado quando a Lixeira for esvaziada."))
            }
        } else {
            EmptyAnalysis(text: L("Analise o disco para explorar pastas e arquivos por tamanho."))
        }
    }

    private func open(_ node: FileNode) {
        guard node.isDirectory else { return }
        model.explorerPath = node.path
        selectedPath = nil
    }

    private func toolbar(current: FileNode, top: FileNode) -> some View {
        HStack(spacing: 10) {
            Button {
                goUp(current, top)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(current === top || current.parent == nil && current.path == top.path)
            .help(L("Subir um nível"))
            breadcrumb(current: current, top: top)
            Spacer()
            Picker(
                L("Modo"),
                selection: Binding(
                    get: { model.explorerMap ? Mode.map : Mode.list }, set: { model.explorerMap = $0 == .map })
            ) {
                ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 130).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func goUp(_ current: FileNode, _ top: FileNode) {
        model.explorerPath = current.parent.flatMap { $0.path == top.path && roots.count != 1 ? nil : $0.path }
        selectedPath = nil
    }

    private func breadcrumb(current: FileNode, top: FileNode) -> some View {
        var chain: [FileNode] = []
        var cursor: FileNode? = current
        while let n = cursor {
            chain.insert(n, at: 0)
            cursor = n.parent
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if roots.count != 1 {
                    Button(L("Este Mac")) {
                        model.explorerPath = nil
                        selectedPath = nil
                    }.buttonStyle(.link)
                    if !chain.isEmpty { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                }
                ForEach(Array(chain.enumerated()), id: \.element.path) { index, item in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    Button(item.name) {
                        model.explorerPath = item.path
                        selectedPath = nil
                    }
                    .buttonStyle(.link).disabled(item === current)
                    .fontWeight(item === current ? .semibold : .regular)
                }
            }
        }
    }
}

private struct ListPane: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode
    @Binding var selectedPath: String?
    let open: (FileNode) -> Void

    var body: some View {
        List(selection: $selectedPath) {
            ForEach(current.children) { child in
                ExplorerRow(node: child, parentSize: max(1, current.size), cls: model.nodeClass(child), open: open)
                    .tag(child.path)
            }
            if current.residual > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 22)
                    Text(L("Itens menores que 1 MB (%@ arquivos no total)", current.fileCount.formatted()))
                        .foregroundStyle(
                            .secondary)
                    Spacer()
                    Text(Fmt.size(current.residual)).monospacedDigit().foregroundStyle(.secondary).frame(
                        width: 76, alignment: .trailing)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct ExplorerRow: View {
    let node: FileNode
    let parentSize: Int64
    let cls: NodeClass
    let open: (FileNode) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.isDirectory ? cls.category.color : .secondary).frame(width: 22)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Circle().fill(cls.safety.color).frame(width: 8, height: 8).help(cls.safety.title)
            SizeBar(fraction: Double(node.size) / Double(parentSize), color: cls.category.color).frame(width: 110)
            Text(Fmt.size(node.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
            if node.isDirectory {
                Button {
                    open(node)
                } label: {
                    Image(systemName: "chevron.right.circle")
                }
                .buttonStyle(.borderless).help(L("Abrir pasta"))
            } else {
                Color.clear.frame(width: 18)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(node) }
        .contextMenu {
            Button(L("Mostrar no Finder")) { revealInFinder(node.path) }
            Button(L("Copiar caminho")) { copyToPasteboard(node.path) }
            if node.isDirectory { Button(L("Abrir aqui")) { open(node) } }
        }
    }
}

private struct Inspector: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let isSelection: Bool
    let onTrash: (FileNode) -> Void

    var body: some View {
        let cls = model.nodeClass(node)
        let verdict = model.trashVerdict(node)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(node.name).font(.headline).lineLimit(1)
                    SafetyBadge(safety: cls.safety)
                    Badge(text: cls.category.title, color: cls.category.color, icon: cls.category.icon)
                }
                Text(Fmt.shortPath(node.path, home: model.home)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(
                        .middle)
                Text(cls.explanation ?? NodeClass.unknown.explanation!).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let consequence = cls.consequence {
                    Label(consequence, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Fmt.size(node.size)).font(.title3.weight(.semibold)).monospacedDigit()
                Text(L("%@ arquivos · alterado %@", node.fileCount.formatted(), Fmt.ago(node.modified)))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Mostrar no Finder")) { revealInFinder(node.path) }
                    Button(role: .destructive) {
                        onTrash(node)
                    } label: {
                        Label(L("Lixeira"), systemImage: "trash")
                    }
                    .disabled(!isSelection || !verdict.isAllowed || model.isBusy)
                    .help(verdict.isAllowed ? L("Mover para a Lixeira") : deniedText(verdict))
                }
            }
        }
        .padding(14).frame(minHeight: 112).background(.bar)
    }

    private func deniedText(_ verdict: SafetyGuard.Verdict) -> String {
        if case .denied(let reason) = verdict { return reason }
        return ""
    }
}

struct TreemapView: View {
    let node: FileNode
    let selectedPath: String?
    let classify: (FileNode) -> NodeClass
    let onSelect: (FileNode) -> Void
    let onOpen: (FileNode) -> Void
    @State private var hovered: String?

    private static let residualID = "__residual__"

    private struct Entry {
        var id: String
        var rect: CGRect
        var node: FileNode?
    }

    private func entries(in size: CGSize) -> [Entry] {
        var weights: [(id: String, weight: Double)] = node.children.prefix(150).map { ($0.path, Double($0.size)) }
        let shown = node.children.prefix(150).reduce(Int64(0)) { $0 + $1.size }
        let rest = node.size - shown
        if rest > 0 { weights.append((Self.residualID, Double(rest))) }
        let byPath = Dictionary(uniqueKeysWithValues: node.children.prefix(150).map { ($0.path, $0) })
        return Treemap.layout(weights, in: TreemapRect(x: 0, y: 0, width: size.width, height: size.height)).map {
            Entry(
                id: $0.id, rect: CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height),
                node: byPath[$0.id])
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cells = entries(in: geo.size)
            let classes = Dictionary(
                uniqueKeysWithValues: cells.compactMap { cell in cell.node.map { (cell.id, classify($0)) } })
            Canvas { context, _ in
                for cell in cells {
                    let rect = cell.rect.insetBy(dx: 1, dy: 1)
                    let cls = classes[cell.id]
                    let color = cell.node == nil ? Color(nsColor: .tertiaryLabelColor) : (cls?.category.color ?? .gray)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 4),
                        with: .color(color.opacity(hovered == cell.id ? 1 : 0.82)))
                    if selectedPath == cell.id {
                        context.stroke(
                            Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 4), with: .color(.white),
                            lineWidth: 3)
                    }
                    if let cls, cls.safety != .review, rect.width > 22, rect.height > 22 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 8, height: 8)),
                            with: .color(cls.safety == .safe ? .white : Color(red: 0.55, green: 0.0, blue: 0.0)))
                    }
                    if rect.width > 64, rect.height > 34 {
                        let name = cell.node?.name ?? L("Itens menores")
                        let size = Fmt.size(cell.node?.size ?? 0)
                        var text = context.resolve(
                            Text(name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
                        text.shading = .color(.white)
                        context.draw(
                            text, in: CGRect(x: rect.minX + 8, y: rect.minY + 18, width: rect.width - 14, height: 16))
                        if cell.node != nil {
                            context.draw(
                                Text(size).font(.system(size: 10)).foregroundColor(.white.opacity(0.85)),
                                in: CGRect(x: rect.minX + 8, y: rect.minY + 33, width: rect.width - 14, height: 14))
                        }
                    }
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { if let n = hit($0.location, cells)?.node { onOpen(n) } }
                    .exclusively(
                        before: SpatialTapGesture().onEnded { if let n = hit($0.location, cells)?.node { onSelect(n) } }
                    )
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = hit(point, cells)?.id
                case .ended: hovered = nil
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let hovered, let cell = cells.first(where: { $0.id == hovered }) {
                    Text(
                        "\(cell.node?.name ?? L("Itens menores")) · \(Fmt.size(cell.node?.size ?? max(0, node.size - node.children.prefix(150).reduce(0) { $0 + $1.size })))"
                    )
                    .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule()).padding(8)
                }
            }
        }
        .padding(8)
        .accessibilityLabel(L("Mapa de tamanho de %@", node.name))
    }

    private func hit(_ point: CGPoint, _ cells: [Entry]) -> Entry? { cells.first { $0.rect.contains(point) } }
}
