import SwiftUI
import TravianZCore

struct SQLConsoleView: View {
    @Environment(GameRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var query = DevTool.snippets[0].sql
    @State private var result = SQLResponse()
    @State private var running = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                TextEditor(text: $query)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                controls
                summary
                resultGrid
            }
            .padding()
            .navigationTitle("SQL konzole")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Zavřít") { dismiss() } } }
        }
    }

    private var controls: some View {
        HStack {
            Menu("Šablony") {
                ForEach(DevTool.snippets, id: \.title) { s in
                    Button(s.title) { query = s.sql }
                }
            }
            Spacer()
            Button {
                Task { await run() }
            } label: {
                if running {
                    ProgressView()
                } else {
                    Label("Spustit", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let error = result.error {
            Text(error).font(.caption.monospaced()).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let set = result.lastSet {
            Text("\(set.rows.count) řádků · \(result.ms ?? 0) ms").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if result.ms != nil {
            Text("OK · ovlivněno \(result.affected ?? 0) řádků").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultGrid: some View {
        let columns = result.lastSet?.columns ?? []
        let rows = result.lastSet?.rows ?? []
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if !columns.isEmpty {
                    GridRow {
                        ForEach(columns.indices, id: \.self) { Text(columns[$0]).bold() }
                    }
                    Divider()
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            cell(rows[r][c])
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
    }

    private func cell(_ value: String) -> some View {
        Text(value).lineLimit(1).foregroundStyle(value == "NULL" ? .secondary : .primary)
    }

    private func run() async {
        running = true
        result = await runtime.sql(query)
        running = false
    }
}
