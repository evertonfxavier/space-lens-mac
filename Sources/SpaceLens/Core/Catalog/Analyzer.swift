import Foundation

public struct CategoryItem: Identifiable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var isDirectory: Bool
    public var safety: Safety
    public var title: String?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct Analysis: Sendable {
    public var categoryBytes: [Category: Int64]
    public var recommendations: [Recommendation]
    /// The biggest things in each category, for the Categories screen.
    public var topItems: [Category: [CategoryItem]] = [:]

    public var scannedBytes: Int64 { categoryBytes.values.reduce(0, +) }

    /// What you can free without losing anything and without a password.
    public var safeFreeable: Int64 {
        recommendations.filter { $0.safety == .safe && !$0.needsAdmin && !$0.sizeIsReference }
            .reduce(0) { $0 + $1.totalSize }
    }
}

/// Reads a scan and answers two questions: where does the space go (by category) and what can I delete.
public final class Analyzer: @unchecked Sendable {
    private struct Matched {
        var cls: NodeClass
        var scope: CatalogEntry.Scope
        var entry: CatalogEntry?
        var group: ArtifactGroup?
        var projectName: String?
    }

    private struct Accumulator {
        var recommendation: Recommendation
    }

    public static let largeOldSize: Int64 = 500 << 20
    public static let largeOldDays = 180

    private let home: String
    private let now: Date
    private let toolExists: @Sendable (String) -> Bool
    private let exact: [String: CatalogEntry]
    private let children: [String: [CatalogEntry]]
    private let artifactsByName: [String: [ArtifactKind]]
    private let cacheLock = NSLock()
    private var listingCache: [String: [String]] = [:]

    public init(home: String, now: Date = Date(), toolExists: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.home = home
        self.now = now
        self.toolExists = toolExists
        var exact: [String: CatalogEntry] = [:]
        var children: [String: [CatalogEntry]] = [:]
        for entry in Catalog.entries(home: home) {
            for match in entry.matches {
                switch match {
                case .path(let path): if exact[path] == nil { exact[path] = entry }
                case .childrenOf(let parent): children[parent, default: []].append(entry)
                }
            }
        }
        self.exact = exact
        self.children = children
        self.artifactsByName = Dictionary(grouping: Catalog.artifactKinds, by: { $0.dirName })
    }

    // MARK: - Classification

    /// Nearest rule on the node or one of its ancestors, else "yours, look before deleting".
    public func classify(_ node: FileNode) -> NodeClass {
        var current: FileNode? = node
        while let candidate = current {
            if let matched = match(candidate) { return matched.cls }
            current = candidate.parent
        }
        return .unknown
    }

    private func match(_ node: FileNode) -> Matched? {
        if let entry = exact[node.path] {
            return Matched(cls: entry.nodeClass, scope: entry.scope, entry: entry)
        }
        if node.isDirectory, let kinds = artifactsByName[node.name], let kind = firstMatching(kinds, node) {
            let group = Catalog.artifactGroups[kind.group]!
            let project = (Self.parent(of: node.path) as NSString).lastPathComponent
            let cls = NodeClass(
                category: .developer, safety: .safe, title: group.title, explanation: group.explanation,
                consequence: group.consequence, entryID: group.id)
            return Matched(cls: cls, scope: .whole, group: group, projectName: project)
        }
        if let candidates = children[Self.parent(of: node.path)] {
            for entry in candidates where entry.childFilter?(node, now) ?? true {
                return Matched(cls: entry.nodeClass, scope: entry.scope, entry: entry)
            }
        }
        return nil
    }

    private func firstMatching(_ kinds: [ArtifactKind], _ node: FileNode) -> ArtifactKind? {
        let parentPath = Self.parent(of: node.path)
        for kind in kinds {
            if !kind.insideMarkers.isEmpty
                && kind.insideMarkers.contains(where: { FileManager.default.fileExists(atPath: node.path + "/" + $0) })
            {
                return kind
            }
            if !kind.siblingMarkers.isEmpty {
                let names = listing(parentPath)
                for marker in kind.siblingMarkers {
                    if marker.hasPrefix("*") {
                        if names.contains(where: { $0.hasSuffix(String(marker.dropFirst())) }) { return kind }
                    } else if names.contains(marker) {
                        return kind
                    }
                }
            }
        }
        return nil
    }

    private func listing(_ path: String) -> [String] {
        cacheLock.lock()
        if let hit = listingCache[path] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        cacheLock.lock()
        listingCache[path] = names
        cacheLock.unlock()
        return names
    }

    // MARK: - Analysis

    public func analyze(_ roots: [FileNode]) -> Analysis {
        var totals: [Category: Int64] = [:]
        var accumulators: [String: Accumulator] = [:]
        var order: [String] = []
        var largeOld: [CleanupItem] = []
        var tops: [Category: [CategoryItem]] = [:]

        func remember(_ node: FileNode, _ cls: NodeClass) {
            guard node.size >= (1 << 20) else { return }
            tops[cls.category, default: []].append(
                CategoryItem(
                    path: node.path, size: node.size, isDirectory: node.isDirectory, safety: cls.safety,
                    title: cls.title))
        }

        func collect(_ matched: Matched, _ node: FileNode) {
            if let entry = matched.entry, entry.actionable {
                if let command = entry.command, !toolExists(command.tool) { return }
                if node.size < entry.minItemSize { return }
                let item = CleanupItem(
                    path: node.path, size: node.size, modified: node.modified, changed: node.changed,
                    preselected: entry.preselect)
                add(item, id: entry.id, to: &accumulators, order: &order) {
                    Recommendation(
                        id: entry.id, title: entry.title, explanation: entry.explanation,
                        consequence: entry.consequence, category: entry.category, safety: entry.safety,
                        mode: entry.mode, items: [], command: entry.command, needsAdmin: entry.admin,
                        preselect: entry.preselect, sizeIsReference: entry.command != nil)
                }
            } else if let group = matched.group {
                guard node.size >= (1 << 20) else { return }
                let stale =
                    node.modified.map { now.timeIntervalSince($0) > Double(Catalog.inactiveDays) * 86_400 } ?? true
                let item = CleanupItem(
                    path: node.path, size: node.size, modified: node.modified, changed: node.changed,
                    label: matched.projectName, preselected: stale)
                add(item, id: group.id, to: &accumulators, order: &order) {
                    Recommendation(
                        id: group.id, title: group.title, explanation: group.explanation,
                        consequence: group.consequence, category: .developer, safety: .safe, mode: .delete,
                        items: [], command: nil, needsAdmin: false, preselect: true, sizeIsReference: false)
                }
            }
        }

        func walk(_ node: FileNode, _ inherited: NodeClass) {
            var current = inherited
            if let matched = match(node) {
                if matched.scope == .whole {
                    totals[matched.cls.category, default: 0] += node.size
                    remember(node, matched.cls)
                    collect(matched, node)
                    return
                }
                current = matched.cls
            }
            if !node.isDirectory {
                totals[current.category, default: 0] += node.size
                remember(node, current)
                if isLargeOld(node, current) {
                    largeOld.append(
                        CleanupItem(
                            path: node.path, size: node.size, modified: node.modified, changed: node.changed,
                            preselected: false))
                }
                return
            }
            totals[current.category, default: 0] += node.residual
            for child in node.children { walk(child, current) }
        }

        for root in roots { walk(root, .unknown) }

        var recommendations = order.compactMap { accumulators[$0]?.recommendation }
        if !largeOld.isEmpty {
            recommendations.append(
                Recommendation(
                    id: "large.old", title: "Arquivos grandes sem uso há mais de 6 meses",
                    explanation:
                        "Arquivos acima de 500 MB que você não abre nem altera há meio ano. Costumam ser vídeos, imagens de disco e arquivos compactados.",
                    consequence:
                        "Vão para a Lixeira, de onde você pode recuperar. Confira cada um: só você sabe se importa.",
                    category: .other, safety: .review, mode: .trash, items: largeOld, command: nil,
                    needsAdmin: false, preselect: false, sizeIsReference: false))
        }
        for index in recommendations.indices {
            recommendations[index].items.sort { $0.size > $1.size }
        }
        recommendations.sort {
            if $0.safety != $1.safety { return $0.safety < $1.safety }
            return $0.totalSize > $1.totalSize
        }
        for category in tops.keys {
            tops[category] = Array(tops[category]!.sorted { $0.size > $1.size }.prefix(60))
        }
        return Analysis(categoryBytes: totals, recommendations: recommendations, topItems: tops)
    }

    private func add(
        _ item: CleanupItem, id: String, to accumulators: inout [String: Accumulator], order: inout [String],
        make: () -> Recommendation
    ) {
        if accumulators[id] == nil {
            accumulators[id] = Accumulator(recommendation: make())
            order.append(id)
        }
        accumulators[id]!.recommendation.items.append(item)
    }

    private func isLargeOld(_ node: FileNode, _ cls: NodeClass) -> Bool {
        guard node.size >= Self.largeOldSize, cls.safety != .keep, node.path.hasPrefix(home + "/"),
            cls.category != .cloud, cls.category != .system, let modified = node.modified
        else { return false }
        return now.timeIntervalSince(modified) > Double(Self.largeOldDays) * 86_400
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
