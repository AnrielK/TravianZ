import SwiftUI
import TravianZCore

struct ToolsView: View {
    @ObservedObject var browser: BrowserModel
    @Environment(GameRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var busy = false
    @State private var confirmReset = false
    @State private var players: [[String]] = []
    @State private var target = 0          // 0 = all players, otherwise the user id

    private var devTarget: DevTool.Target { target == 0 ? .allPlayers : .player(target) }

    var body: some View {
        NavigationStack {
            Form {
                toolsSection
                playersSection
                serverSection
            }
            .disabled(busy)
            .navigationTitle("Nástroje")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } } }
            .task { await refresh() }
            .confirmationDialog("Smazat všechny hráče a vesnice a vytvořit nový svět?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Vytvořit nový svět", role: .destructive) { Task { await newWorld() } }
            }
        }
    }

    private var toolsSection: some View {
        Section {
            Picker("Hráč", selection: $target) {
                Text("Všichni hráči").tag(0)
                ForEach(players.indices, id: \.self) { i in
                    Text(players[i][1]).tag(Int(players[i][0]) ?? -1)
                }
            }
            ForEach(DevTool.allCases) { tool in
                toolButton(tool)
            }
        } header: {
            Text("Testovací nástroje")
        } footer: {
            if !message.isEmpty { Text(message) }
        }
    }

    private var playersSection: some View {
        Section("Hráči ve světě") {
            if players.isEmpty {
                Text("Zatím nikdo – zaregistrujte se (Menu → Registrace).").foregroundStyle(.secondary)
            }
            ForEach(players.indices, id: \.self) { i in
                playerRow(players[i])
            }
        }
    }

    private func playerRow(_ p: [String]) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(p[1]).bold()
                Text("\(p[2]) · vesnice \(p[4]) · populace \(p[5])").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(p[3]) zlata").font(.caption)
        }
    }

    private var serverSection: some View {
        @Bindable var runtime = runtime
        return Section("Server") {
            LabeledContent("Adresa", value: runtime.baseURL.absoluteString)
            LabeledContent("Admin", value: "Admin / \(runtime.secrets.adminPassword)")
                .textSelection(.enabled)
            LabeledContent("Multihunter, Support", value: "stejné heslo")
            Toggle("Automatizace (cron)", isOn: $runtime.tickEnabled)
            if !runtime.lastTick.isEmpty {
                Text("\(runtime.tickCount) ticků · \(runtime.tickErrors) chyb · \(runtime.lastTick)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            }
            Button("Spustit automatizaci teď") {
                Task { await runtime.tick(); message = "✓ Tick: \(runtime.lastTick)" }
            }
            Button("Nový svět…", role: .destructive) { confirmReset = true }
        }
    }

    private func toolButton(_ tool: DevTool) -> some View {
        Button {
            Task { await run(tool) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(tool.title, systemImage: tool.icon)
                if let help = tool.help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run(_ tool: DevTool) async {
        busy = true
        let r = await runtime.sql(tool.sql(for: devTarget))
        if let error = r.error {
            message = "✖ \(tool.title): \(error)"
        } else {
            message = "✓ \(tool.title) (\(r.affected ?? 0) řádků)"
        }
        await runtime.tick()
        busy = false
        browser.reload()
        await refresh()
    }

    private func newWorld() async {
        busy = true
        do {
            try await runtime.newWorld()
            message = "✓ Nový svět vytvořen"
        } catch {
            message = "✖ \(error.localizedDescription)"
        }
        busy = false
        await refresh()
    }

    private func refresh() async {
        let r = await runtime.sql(DevTool.playersQuery)
        players = (r.lastSet?.rows ?? []).filter { $0.count >= 7 }
    }
}
