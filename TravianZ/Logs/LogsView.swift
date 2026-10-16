import SwiftUI

struct LogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var which = 0
    @State private var text = ""
    @State private var onlyProblems = false

    private let files: [(String, URL)] = [
        ("PHP", Paths.phpErrorLog), ("Server", Paths.serverLog), ("Cron", Paths.tickLog),
        ("MariaDB", Paths.mariadbLog), ("Start", Paths.setupLog), ("Přístupy", Paths.gameAccessLog),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $which) {
                    ForEach(files.indices, id: \.self) { Text(files[$0].0).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                Toggle("Jen chyby a varování", isOn: $onlyProblems).font(.caption).padding(.horizontal)
                logText
            }
            .navigationTitle("Logy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zavřít") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: files[which].1) { Image(systemName: "square.and.arrow.up") }
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onAppear { load() }
            .onChange(of: which) { _, _ in load() }
            .onChange(of: onlyProblems) { _, _ in load() }
        }
    }

    private var logText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(prázdné)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end") }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: files[which].1) else { text = ""; return }
        let lines = String(decoding: data.suffix(120_000), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasSuffix(" Accepted") && !$0.hasSuffix(" Closing") }
            .filter { line in
                guard onlyProblems else { return true }
                let l = line.lowercased()
                return l.contains("error") || l.contains("warning") || l.contains("fatal") || l.contains("exception")
                    || l.contains("notice") || l.contains(" [5") || l.contains(" [4")
            }
        text = lines.suffix(600).joined(separator: "\n")
    }
}
