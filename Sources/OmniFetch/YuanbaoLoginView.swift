import SwiftUI
import WebKit
import OmniFetchCore

struct PlatformLoginView: View {
    let title: String
    let message: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                OmniMarkView(size: 18, arcColor: OmniColor.accent, arrowColor: OmniColor.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OmniFont.sheetTitle)
                        .foregroundStyle(OmniColor.ink)
                    Text(message)
                        .font(OmniFont.meta)
                        .foregroundStyle(OmniColor.inkMuted)
                }
                Spacer()
                if let host = url.host {
                    Text(host)
                        .font(OmniFont.telemetrySmall)
                        .foregroundStyle(OmniColor.inkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(OmniColor.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(OmniColor.line, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(OmniColor.surface)

            Rectangle().fill(OmniColor.line).frame(height: 1)

            LoginWebView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(OmniColor.line).frame(height: 1)

            HStack {
                Text("登录会话仅保存在本机 WebKit 数据存储中")
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(OmniButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(OmniColor.surface)
        }
        .frame(width: 860, height: 660)
        .background(OmniColor.canvas)
    }
}

private struct LoginWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        if url.host == "yuanbao.tencent.com" { webView.customUserAgent = FetchHeaders.desktopUA }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
