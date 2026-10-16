import SwiftUI

/// A second browser with its own persistent cookies – log in as another player to test interactions.
@MainActor
struct SecondPlayerView: View {
    @Environment(GameRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserModel(profile: SecondPlayerView.profileID)

    static let profileID: UUID = {
        let key = "TravianZ.secondPlayerProfile"
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    var body: some View {
        NavigationStack {
            WebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Druhý hráč")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Zavřít") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button("Vesnice") { browser.load(runtime.url("dorf1.php")) }
                            Button("Mapa") { browser.load(runtime.url("karte.php")) }
                            Button("Zprávy") { browser.load(runtime.url("nachrichten.php")) }
                            Button("Registrace") { browser.load(runtime.url("anmelden.php")) }
                            Button("Přihlášení") { browser.load(runtime.url("login.php")) }
                            Button("Odhlásit (smazat cookies)", role: .destructive) {
                                Task { await browser.clearCookies(); browser.load(runtime.url("login.php")) }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
                .onAppear { if browser.webView.url == nil { browser.load(runtime.url("login.php")) } }
        }
    }
}
