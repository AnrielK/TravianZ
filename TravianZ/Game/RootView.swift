import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @Environment(GameRuntime.self) private var runtime
    @StateObject private var browser = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case tools, logs, sql, secondPlayer, settings
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            WebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
            overlay
        }
        .safeAreaInset(edge: .bottom) { toolbar }
        .alert("Aplikace minule spadla při startu", isPresented: crashAlertShown) {
            Button("Logy") { runtime.previousCrash = nil; sheet = .logs }
            Button("OK", role: .cancel) { runtime.previousCrash = nil }
        } message: {
            Text(runtime.previousCrash ?? "")
        }
        .onAppear { runtime.start() }
        .onChange(of: runtime.state) { _, state in
            if state == .running && browser.webView.url == nil { browser.load(runtime.baseURL) }
        }
        .onChange(of: runtime.reloadToken) { _, _ in browser.load(runtime.url("dorf1.php")) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { runtime.ensureRunning() }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .tools: ToolsView(browser: browser)
            case .logs: LogsView()
            case .sql: SQLConsoleView()
            case .secondPlayer: SecondPlayerView()
            case .settings: SettingsView()
            }
        }
    }

    private var crashAlertShown: Binding<Bool> {
        Binding(get: { runtime.previousCrash != nil }, set: { if !$0 { runtime.previousCrash = nil } })
    }

    @ViewBuilder
    private var overlay: some View {
        switch runtime.state {
        case .idle:
            StatusCard(icon: "hourglass", text: "Spouštím…", spinner: true)
        case .working(let message):
            StatusCard(icon: "hourglass", text: message, spinner: true)
        case .failed(let message):
            StatusCard(icon: "exclamationmark.triangle", text: message, spinner: false) {
                Button("Zkusit znovu") { runtime.start() }.buttonStyle(.borderedProminent)
                Button("Logy") { sheet = .logs }
            }
        case .running:
            if let error = browser.lastError {
                StatusCard(icon: "bolt.horizontal.circle", text: error, spinner: false) {
                    Button("Načíst znovu") { browser.load(runtime.baseURL) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            barButton("chevron.left", "Zpět") { browser.webView.goBack() }.disabled(!browser.canGoBack)
            barButton("arrow.clockwise", "Obnovit") { browser.reload() }
            gameMenu
            barButton("wand.and.stars", "Nástroje") { sheet = .tools }
            barButton("person.2", "2. hráč") { sheet = .secondPlayer }
            Menu {
                Button { sheet = .logs } label: { Label("Logy", systemImage: "text.alignleft") }
                Button { sheet = .sql } label: { Label("SQL konzole", systemImage: "cylinder.split.1x2") }
                Button { sheet = .settings } label: { Label("Nastavení světa", systemImage: "gearshape") }
            } label: {
                barLabel("ellipsis.circle", "Více")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .background(.bar)
    }

    private var gameMenu: some View {
        Menu {
            Button { go("dorf1.php") } label: { Label("Pole (dorf1)", systemImage: "leaf") }
            Button { go("dorf2.php") } label: { Label("Centrum vesnice", systemImage: "building.2") }
            Button { go("karte.php") } label: { Label("Mapa", systemImage: "map") }
            Button { go("build.php?id=39") } label: { Label("Shromaždiště", systemImage: "flag") }
            Button { go("berichte.php") } label: { Label("Hlášení", systemImage: "doc.text") }
            Button { go("nachrichten.php") } label: { Label("Zprávy", systemImage: "envelope") }
            Button { go("statistiken.php") } label: { Label("Statistiky", systemImage: "chart.bar") }
            Button { go("dorf3.php") } label: { Label("Přehled vesnic", systemImage: "square.grid.3x3") }
            Divider()
            Button { go("anmelden.php") } label: { Label("Registrace", systemImage: "person.badge.plus") }
            Button { go("login.php") } label: { Label("Přihlášení", systemImage: "person.crop.circle") }
            Button { go("logout.php") } label: { Label("Odhlásit", systemImage: "rectangle.portrait.and.arrow.right") }
            Button { go("Admin/") } label: { Label("Admin panel", systemImage: "lock.shield") }
        } label: {
            barLabel("square.grid.2x2", "Menu")
        }
    }

    private func go(_ path: String) { browser.load(runtime.url(path)) }

    private func barButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(icon, title) }
    }

    private func barLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 18))
            Text(title).font(.system(size: 10))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
