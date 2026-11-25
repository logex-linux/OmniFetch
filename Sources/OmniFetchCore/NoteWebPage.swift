import Foundation
import WebKit

/// Read a note in the app's own WebKit session only when the user selects it.
/// Session cookies stay in WebKit. Only the requested note is passed to the downloader.
@MainActor
final class NoteWebPage: NSObject, WKNavigationDelegate {
    private let web = WKWebView()
    private var completion: CheckedContinuation<(String, URL), Error>?
    private var timeout: Task<Void, Never>?

    func read(_ url: URL) async throws -> (String, URL) {
        try Task.checkCancellation()
        web.navigationDelegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(EngineError.unavailable("小红书页面加载超时，请检查应用内登录状态")))
                }
                web.load(URLRequest(url: url))
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true {
            guard let url = action.request.url, url.scheme == "https",
                  url.isOn("xiaohongshu.com") || url.isOn("xhslink.com") else {
                decisionHandler(.cancel)
                finish(.failure(EngineError.unavailable("分享链接未指向小红书笔记")))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = webView.url, page.isOn("xiaohongshu.com") else { return }
        if let error = XiaohongshuEngine.accessError(page) { finish(.failure(error)); return }
        guard let id = XiaohongshuEngine.noteID(from: page) else {
            finish(.failure(EngineError.unavailable("请提供单篇小红书笔记的分享链接")))
            return
        }
        Task {
            do {
                let result = try await webView.callAsyncJavaScript(
                    "const n = window.__INITIAL_STATE__?.note?.noteDetailMap?.[id]?.note; return n ? JSON.stringify(n) : null;",
                    arguments: ["id": id], in: nil, contentWorld: .page)
                guard let note = result as? String,
                      let json = try JSONSerialization.jsonObject(with: Data(note.utf8)) as? [String: Any],
                      !json.isEmpty else {
                    throw EngineError.unavailable("当前小红书登录状态无法查看这篇笔记，请检查原始分享链接")
                }
                let data = try JSONSerialization.data(withJSONObject: ["note": ["noteDetailMap": [id: ["note": json]]]])
                finish(.success((String(decoding: data, as: UTF8.self), page)))
            } catch { finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<(String, URL), Error>) {
        guard let continuation = completion else { return }
        completion = nil
        timeout?.cancel()
        web.navigationDelegate = nil
        web.stopLoading()
        continuation.resume(with: result)
    }
}
