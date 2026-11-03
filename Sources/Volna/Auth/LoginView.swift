import SwiftUI
import WebKit

/// Yandex OAuth (implicit flow) in a web view; the token is read from the redirect fragment.
struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var showWeb = false
    @State private var manualToken = ""

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.white)
                    .frame(width: 128, height: 128)
                    .glassEffect(.regular.tint(.orange.opacity(0.35)), in: .circle)

                VStack(spacing: 8) {
                    Text("Волна")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Только музыка. Ничего лишнего.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showWeb = true
                } label: {
                    Label("Войти через Яндекс", systemImage: "person.crop.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .controlSize(.large)

                DisclosureGroup("Вставить токен вручную") {
                    HStack {
                        SecureField("OAuth-токен", text: $manualToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("OK") {
                            let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !token.isEmpty else { return }
                            Task { await session.login(token: token) }
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(.top, 8)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .sheet(isPresented: $showWeb) {
            NavigationStack {
                YandexOAuthWebView { token in
                    showWeb = false
                    Task { await session.login(token: token) }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Яндекс ID")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена", systemImage: "xmark") { showWeb = false }
                    }
                }
            }
        }
    }
}

struct YandexOAuthWebView: UIViewRepresentable {
    /// Client id of the official Yandex Music app; the only one allowed to read the music API.
    private static let authURL = URL(
        string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d"
    )!

    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: Self.authURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        private var delivered = false

        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let token = Self.token(in: navigationAction.request.url) else { return .allow }
            deliver(token)
            return .cancel
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let token = Self.token(in: webView.url) { deliver(token) }
        }

        private func deliver(_ token: String) {
            guard !delivered else { return }
            delivered = true
            onToken(token)
        }

        private static func token(in url: URL?) -> String? {
            guard let fragment = url?.fragment, fragment.contains("access_token=") else { return nil }
            var parts = URLComponents()
            parts.query = fragment
            return parts.queryItems?.first(where: { $0.name == "access_token" })?.value
        }
    }
}
