#if SNAPSHOT_TOOLS
    import Foundation

    /// Fake but realistic scan used only by the screenshot harness (`make snapshots`). Not part of release builds.
    @MainActor
    extension AppModel {
        func loadDemo() {
            let fm = FileManager.default
            let h = home
            for marker in [
                "Projects/webapp/package.json", "Projects/api/package.json", "Projects/mobile/Podfile",
                "Projects/svc/svc.csproj",
            ] {
                let path = h + "/" + marker
                try? fm.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                fm.createFile(atPath: path, contents: Data("x".utf8))
            }
            let gb: Int64 = 1_000_000_000
            let mb: Int64 = 1_000_000
            let now = Date()
            func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

            func file(_ parent: String, _ name: String, _ size: Int64, days: Double = 5) -> FileNode {
                FileNode(
                    name: name, path: parent + "/" + name, isDirectory: false, size: size, fileCount: 1,
                    modified: ago(days), changed: ago(days))
            }
            func dir(
                _ parent: String, _ name: String, residual: Int64 = 0, days: Double = 5,
                _ build: (String) -> [FileNode] = { _ in [] }
            ) -> FileNode {
                let path = parent + "/" + name
                let node = FileNode(name: name, path: path, isDirectory: true, modified: ago(days), changed: ago(days))
                let kids = build(path)
                node.children = kids.sorted { $0.size > $1.size }
                for child in node.children { child.parent = node }
                node.residual = residual
                node.fileCount = kids.reduce(0) { $0 + $1.fileCount } + Int(residual / 40_000)
                node.recomputeSize()
                node.isFinalized = true
                return node
            }

            let root = dir("", "demo", residual: 400 * mb) { _ in [] }
            let library = dir(h, "Library", residual: 2 * gb) { l in
                [
                    dir(l, "Caches", residual: gb) { c in
                        [
                            dir(c, "com.google.Chrome", residual: 0) { _ in
                                [file(c + "/com.google.Chrome", "Cache_Data", 8_200 * mb)]
                            },
                            dir(c, "com.spotify.client") { _ in [file(c + "/com.spotify.client", "Storage", 4_900 * mb)]
                            },
                            dir(c, "Homebrew") { _ in [file(c + "/Homebrew", "downloads", 3_200 * mb, days: 40)] },
                            dir(c, "com.apple.Safari") { _ in [file(c + "/com.apple.Safari", "WebKitCache", 2_500 * mb)]
                            },
                            dir(c, "pip") { _ in [file(c + "/pip", "wheels", 1_100 * mb, days: 90)] },
                        ]
                    },
                    dir(l, "Developer", residual: 0) { d in
                        [
                            dir(d, "Xcode") { x in
                                [
                                    dir(x, "DerivedData") { dd in [file(dd, "Build.noindex", 14_300 * mb)] },
                                    dir(x, "iOS DeviceSupport") { ds in
                                        [
                                            dir(ds, "17.5 (21F79)") { _ in
                                                [file(ds + "/17.5 (21F79)", "Symbols", 5_200 * mb, days: 200)]
                                            },
                                            dir(ds, "18.1 (22B83)") { _ in
                                                [file(ds + "/18.1 (22B83)", "Symbols", 4_100 * mb, days: 60)]
                                            },
                                        ]
                                    },
                                    dir(x, "Archives") { a in
                                        [file(a, "MyApp 2025-09-01.xcarchive", 3_100 * mb, days: 120)]
                                    },
                                ]
                            },
                            dir(d, "CoreSimulator") { cs in
                                [dir(cs, "Devices") { dv in [file(dv, "A1B2C3.sim", 12_100 * mb, days: 30)] }]
                            },
                        ]
                    },
                    dir(l, "Application Support", residual: 3 * gb) { a in
                        [
                            dir(a, "Slack") { s in
                                [
                                    dir(s, "Cache") { _ in [file(s + "/Cache", "data_0", 1_400 * mb)] },
                                    file(s, "storage.db", 800 * mb),
                                ]
                            },
                            dir(a, "Code") { c in
                                [
                                    dir(c, "CachedData") { _ in [file(c + "/CachedData", "bundle", 900 * mb)] },
                                    file(c, "state.vscdb", 300 * mb),
                                ]
                            },
                        ]
                    },
                    dir(l, "Containers") { c in
                        [dir(c, "com.docker.docker") { d in [file(d, "Docker.raw", 6_500 * mb)] }]
                    },
                ]
            }
            let projects = dir(h, "Projects", residual: 600 * mb) { p in
                [
                    dir(p, "webapp", days: 100) { w in
                        [
                            dir(w, "node_modules", days: 100) { n in [file(n, "bundle.bin", 2_100 * mb, days: 100)] },
                            file(w, "dump.sql", 40 * mb),
                        ]
                    },
                    dir(p, "api", days: 3) { w in
                        [dir(w, "node_modules", days: 3) { n in [file(n, "bundle.bin", 1_300 * mb, days: 3)] }]
                    },
                    dir(p, "mobile", days: 200) { w in
                        [dir(w, "Pods", days: 200) { n in [file(n, "pods.bin", 1_700 * mb, days: 200)] }]
                    },
                    dir(p, "svc", days: 70) { w in
                        [
                            dir(w, "bin", days: 70) { n in [file(n, "svc.dll", 700 * mb, days: 70)] },
                            dir(w, "obj", days: 70) { n in [file(n, "cache.bin", 500 * mb, days: 70)] },
                        ]
                    },
                ]
            }
            let movies = dir(h, "Movies") { m in
                [
                    file(m, "Férias 2023.mov", 11_800 * mb, days: 500),
                    file(m, "Reunião gravada.mp4", 2_300 * mb, days: 40),
                    file(m, "Tutorial.mkv", 1_900 * mb, days: 300),
                ]
            }
            let pictures = dir(h, "Pictures") { p in
                [dir(p, "Photos Library.photoslibrary", residual: 0) { l in [file(l, "originals.bin", 24_000 * mb)] }]
            }
            let documents = dir(h, "Documents", residual: 500 * mb) { d in
                [file(d, "Backup-2022.zip", 3_400 * mb, days: 700), file(d, "Tese.pdf", 90 * mb)]
            }
            let downloads = dir(h, "Downloads", residual: 300 * mb) { d in
                [
                    file(d, "Xcode_16.dmg", 4_200 * mb, days: 20), file(d, "ubuntu-24.04.iso", 5_800 * mb, days: 150),
                    file(d, "relatorio-final.pdf", 60 * mb, days: 200), file(d, "setup.pkg", 800 * mb, days: 10),
                ]
            }
            let trash = dir(h, ".Trash") { t in
                [file(t, "old-project.zip", 4_800 * mb, days: 20), file(t, "video.mov", 2_000 * mb, days: 50)]
            }
            let npm = dir(h, ".npm") { n in [dir(n, "_cacache") { c in [file(c, "content-v2", 5_400 * mb)] }] }
            let vms = dir(h, "Parallels") { v in [file(v, "Windows 11.pvm", 38_000 * mb, days: 20)] }
            let misc = dir(h, "outros", residual: 0) { o in [file(o, "dataset.csv", 1_500 * mb, days: 20)] }

            let home = dir("", "demo", residual: 1_200 * mb) { _ in
                [library, projects, movies, pictures, documents, downloads, trash, npm, vms, misc]
            }
            _ = root
            let homeNode = FileNode(
                name: (h as NSString).lastPathComponent, path: h, isDirectory: true, modified: now, changed: now)
            homeNode.children = home.children.sorted { $0.size > $1.size }
            for child in homeNode.children { child.parent = homeNode }
            homeNode.residual = home.residual
            homeNode.fileCount = 482_113
            homeNode.recomputeSize()
            homeNode.isFinalized = true

            let result = ScanResult(
                roots: [homeNode], deniedPaths: [], deniedCount: 0, duration: 38, cancelled: false, finishedAt: now)
            let analyzer = Analyzer(home: h, now: now, toolExists: { _ in true })
            var analysis = analyzer.analyze(result.roots)
            if let snap = TimeMachineSnapshots.recommendation(dates: ["2026-11-07-101010", "2026-11-08-091500"]) {
                analysis.recommendations.append(snap)
            }
            self.scan = result
            self.analyzer = analyzer
            self.analysis = analysis
            self.usage = DiskUsage(total: 494 * gb, availableImportant: 104 * gb, availableRaw: 86 * gb)
            self.summary = ScanSummary(result: result, analysis: analysis, scope: .home)
            self.selection = Dictionary(
                uniqueKeysWithValues: analysis.recommendations.map {
                    ($0.id, Set($0.items.filter(\.preselected).map(\.path)))
                })
            self.fullDiskAccess = true
            self.history = [
                RunRecord(
                    routineID: UUID(), routineName: "Caches e logs toda semana", date: ago(2), applied: true,
                    freed: 3_400 * mb, itemCount: 41, message: "Liberou 3,4 GB em 41 item(ns)."),
                RunRecord(
                    routineID: nil, routineName: "Limpeza rápida", date: ago(9), applied: true, freed: 12_900 * mb,
                    itemCount: 17, message: "Liberou 12,9 GB. 17 item(ns)."),
                RunRecord(
                    routineID: UUID(), routineName: "Instaladores antigos", date: ago(12), applied: false,
                    potential: 5_000 * mb, itemCount: 3,
                    message: "Poderia liberar 5 GB em 3 item(ns). A rotina está em modo “só avisar”."),
            ]
            for index in routines.indices { routines[index].lastRun = ago(Double(index) + 1) }
            self.duplicates = .done([
                DuplicateGroup(
                    size: 2_300 * mb,
                    files: [
                        DuplicateFile(path: h + "/Movies/Reunião gravada.mp4", modified: ago(40)),
                        DuplicateFile(path: h + "/Downloads/Reunião gravada (1).mp4", modified: ago(30)),
                        DuplicateFile(path: h + "/Documents/Reunião gravada.mp4", modified: ago(20)),
                    ]),
                DuplicateGroup(
                    size: 800 * mb,
                    files: [
                        DuplicateFile(path: h + "/Downloads/setup.pkg", modified: ago(10)),
                        DuplicateFile(path: h + "/Desktop/setup.pkg", modified: ago(8)),
                    ]),
            ])
            self.duplicateSelection = Set([
                h + "/Downloads/Reunião gravada (1).mp4", h + "/Documents/Reunião gravada.mp4",
                h + "/Desktop/setup.pkg",
            ])
            self.expandedRecs = ["caches.user", "artifact.node"]
            self.focusedCategory = .developer
        }
    }
#endif
