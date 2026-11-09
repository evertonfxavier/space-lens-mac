import SwiftUI

struct RoutinesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Routine?

    var body: some View {
        List {
            Text(
                "Rotinas rodam sozinhas enquanto o SpaceLens estiver aberto na barra de menus (ative “Abrir ao iniciar sessão” nos Ajustes). Elas nunca pedem senha, só mexem em itens recriáveis ou mandam para a Lixeira, e mostram o resultado no Histórico. “Só avisar” apenas calcula quanto daria para liberar."
            )
            .font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
            ForEach(model.routines) { routine in RoutineRow(routine: routine, edit: { editing = routine }) }
            if model.routines.isEmpty {
                Text("Nenhuma rotina. Crie uma pelo botão “Nova rotina”.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Em branco…") {
                        editing = Routine(
                            name: "Nova rotina", schedule: .weekly(weekday: 1, hour: 10, minute: 0),
                            task: .cleanCaches(minAgeDays: 7))
                    }
                    Divider()
                    ForEach(Routine.presets(home: model.home)) { preset in
                        Button(preset.name) {
                            model.upsert(
                                Routine(
                                    name: preset.name, schedule: preset.schedule, task: preset.task, apply: preset.apply
                                ))
                        }
                    }
                } label: {
                    Label("Nova rotina", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { RoutineEditor(routine: $0) }
    }
}

struct RoutineRow: View {
    @EnvironmentObject var model: AppModel
    let routine: Routine
    let edit: () -> Void

    var body: some View {
        let running = model.runningRoutines.contains(routine.id)
        HStack(alignment: .top, spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { routine.enabled },
                    set: { on in
                        var r = routine
                        r.enabled = on
                        model.upsert(r)
                    })
            )
            .toggleStyle(.switch).labelsHidden().padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(routine.name).font(.headline)
                    Badge(
                        text: routine.apply ? "Executa a limpeza" : "Só avisa", color: routine.apply ? .green : .blue,
                        icon: routine.apply ? "sparkles" : "bell")
                }
                Text(routine.task.detail).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(routine.schedule.summary(), systemImage: "clock")
                    if routine.enabled {
                        Label("Próxima: \(Fmt.dateTimeString(routine.nextRun()))", systemImage: "calendar")
                    }
                    Label("Última: \(routine.lastRun.map(Fmt.ago) ?? "nunca")", systemImage: "checkmark.circle")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if running { ProgressView().controlSize(.small) }
            Button("Rodar agora") { model.runNow(routine) }.disabled(running)
            Button {
                edit()
            } label: {
                Image(systemName: "pencil")
            }.help("Editar")
            Button(role: .destructive) {
                model.deleteRoutine(routine)
            } label: {
                Image(systemName: "trash")
            }.help("Excluir")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.vertical, 6)
        .opacity(routine.enabled ? 1 : 0.6)
    }
}

struct RoutineEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine

    private enum TaskKind: String, CaseIterable, Identifiable {
        case caches, trash, downloads, projects, lowSpace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .caches: return "Limpar caches e logs seguros"
            case .trash: return "Esvaziar a Lixeira"
            case .downloads: return "Limpar Downloads antigos"
            case .projects: return "Limpar projetos inativos"
            case .lowSpace: return "Avisar quando faltar espaço"
            }
        }
    }

    private enum ScheduleKind: String, CaseIterable, Identifiable {
        case hours, daily, weekly, monthly
        var id: String { rawValue }
        var title: String {
            ["hours": "A cada N horas", "daily": "Todo dia", "weekly": "Toda semana", "monthly": "Todo mês"][rawValue]!
        }
    }

    @State private var taskKind: TaskKind = .caches
    @State private var days = 7
    @State private var installersOnly = true
    @State private var gb = 20
    @State private var roots: [String] = []
    @State private var scheduleKind: ScheduleKind = .weekly
    @State private var hours = 6
    @State private var time = Date()
    @State private var weekday = 1
    @State private var monthDay = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Nome", text: $routine.name)
                Picker("O que fazer", selection: $taskKind) { ForEach(TaskKind.allCases) { Text($0.title).tag($0) } }
                switch taskKind {
                case .caches: Stepper("Só itens parados há \(days)+ dias", value: $days, in: 1...365)
                case .trash: Stepper("Só o que está na Lixeira há \(days)+ dias", value: $days, in: 0...365)
                case .downloads:
                    Stepper("Só itens com \(days)+ dias", value: $days, in: 1...730)
                    Toggle("Apenas instaladores (.dmg, .pkg, .iso)", isOn: $installersOnly)
                case .projects:
                    Stepper("Só projetos sem alteração há \(days)+ dias", value: $days, in: 7...730)
                    VStack(alignment: .leading) {
                        ForEach(roots, id: \.self) { root in
                            HStack {
                                Text(root.replacingOccurrences(of: model.home, with: "~")).font(.caption.monospaced())
                                Spacer()
                                Button {
                                    roots.removeAll { $0 == root }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless)
                            }
                        }
                        Button("Adicionar pasta de projetos…") { pickFolder() }
                    }
                case .lowSpace: Stepper("Avisar abaixo de \(gb) GB livres", value: $gb, in: 1...500)
                }
                Divider()
                Picker("Quando", selection: $scheduleKind) { ForEach(ScheduleKind.allCases) { Text($0.title).tag($0) } }
                switch scheduleKind {
                case .hours: Stepper("A cada \(hours) hora(s)", value: $hours, in: 1...168)
                case .daily: DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                case .weekly:
                    Picker("Dia", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1].capitalized).tag($0) }
                    }
                    DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                case .monthly:
                    Stepper("Dia \(monthDay) do mês", value: $monthDay, in: 1...28)
                    DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                }
                Divider()
                Toggle("Executar a limpeza (desligado: só calcula e avisa)", isOn: $routine.apply)
                Toggle("Notificar o resultado", isOn: $routine.notify)
                if routine.apply, taskKind == .downloads || taskKind == .projects {
                    Text(
                        taskKind == .downloads
                            ? "Downloads vão para a Lixeira, não são apagados de vez."
                            : "Projetos inativos têm só os arquivos recriáveis removidos (node_modules, target, .venv…), nunca o código."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(
                        routine.name.trimmingCharacters(in: .whitespaces).isEmpty
                            || (taskKind == .projects && roots.isEmpty))
            }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: load)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: model.home)
        if panel.runModal() == .OK { roots += panel.urls.map(\.path).filter { !roots.contains($0) } }
    }

    private func load() {
        switch routine.task {
        case .cleanCaches(let d):
            taskKind = .caches
            days = d
        case .emptyTrash(let d):
            taskKind = .trash
            days = d
        case .cleanDownloads(let d, let only):
            taskKind = .downloads
            days = d
            installersOnly = only
        case .cleanProjectArtifacts(let r, let d):
            taskKind = .projects
            days = d
            roots = r
        case .lowSpaceAlert(let g):
            taskKind = .lowSpace
            gb = g
        }
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
        switch routine.schedule {
        case .everyHours(let h):
            scheduleKind = .hours
            hours = h
        case .daily(let h, let m):
            scheduleKind = .daily
            time = at(h, m)
        case .weekly(let w, let h, let m):
            scheduleKind = .weekly
            weekday = w
            time = at(h, m)
        case .monthly(let d, let h, let m):
            scheduleKind = .monthly
            monthDay = d
            time = at(h, m)
        }
    }

    private func save() {
        switch taskKind {
        case .caches: routine.task = .cleanCaches(minAgeDays: days)
        case .trash: routine.task = .emptyTrash(olderThanDays: days)
        case .downloads: routine.task = .cleanDownloads(olderThanDays: days, installersOnly: installersOnly)
        case .projects: routine.task = .cleanProjectArtifacts(roots: roots, inactiveDays: days)
        case .lowSpace: routine.task = .lowSpaceAlert(thresholdGB: gb)
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let h = parts.hour ?? 0
        let m = parts.minute ?? 0
        switch scheduleKind {
        case .hours: routine.schedule = .everyHours(hours)
        case .daily: routine.schedule = .daily(hour: h, minute: m)
        case .weekly: routine.schedule = .weekly(weekday: weekday, hour: h, minute: m)
        case .monthly: routine.schedule = .monthly(day: monthDay, hour: h, minute: m)
        }
        routine.createdAt = routine.lastRun == nil ? Date() : routine.createdAt
        model.upsert(routine)
        dismiss()
    }
}
