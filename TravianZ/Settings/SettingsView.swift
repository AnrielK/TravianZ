import SwiftUI
import TravianZCore

struct SettingsView: View {
    @Environment(GameRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var world = WorldSettings.load()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Grafika", selection: $world.graphicPack) {
                        ForEach(WorldSettings.graphicPacks, id: \.path) { Text($0.name).tag($0.path) }
                    }
                    Picker("Jazyk", selection: $world.language) {
                        ForEach(WorldSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text("Vzhled")
                } footer: {
                    Text("Platí hned po uložení.")
                }
                Section {
                    Stepper("Rychlost hry: ×\(world.speed)", value: $world.speed, in: 1...1000, step: world.speed < 10 ? 1 : 10)
                    Stepper("Rychlost vojsk: ×\(world.troopSpeed)", value: $world.troopSpeed, in: 1...100)
                } header: {
                    Text("Rychlost")
                } footer: {
                    Text("Zapíše se do GameEngine/config.php (SPEED, INCREASE_SPEED) a platí hned.")
                }
                Section {
                    Picker("Mapa", selection: $world.worldMax) {
                        ForEach(WorldSettings.worldSizes, id: \.self) { n in
                            Text("\(n * 2 + 1) × \(n * 2 + 1)").tag(n)
                        }
                    }
                    Toggle("Všechny nové funkce v11", isOn: $world.newFunctions)
                } header: {
                    Text("Nový svět")
                } footer: {
                    Text("Nové funkce: hrdina T4 (předměty, dobrodružství, aukce), Hunové, Egypťané, Sparťané, Vikingové, bonusy aliancí a další. Platí při vytvoření nového světa (Nástroje → Nový svět).")
                }
                Section("Data") {
                    LabeledContent("Logy", value: "Soubory → Na iPhonu → TravianZ → logs")
                    LabeledContent("PHP + MariaDB", value: "v aplikaci, offline")
                }
            }
            .navigationTitle("Nastavení světa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zavřít") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Uložit") {
                        let new = world
                        Task { await runtime.updateSettings(new) }
                        dismiss()
                    }
                }
            }
        }
    }
}
