import SwiftUI
import WebKit
import AVFoundation

/// 原生错误提示：仅在加载失败时显示，正常启动不会出现
final class Status: ObservableObject {
    @Published var text: String = ""
    @Published var ready: Bool = false
}

@main
struct ABandOnApp: App {
    @StateObject private var status = Status()

    init() {
        // 播放类音频：静音开关打开时也能出声
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup { RootView(status: status) }
    }
}

struct RootView: View {
    @ObservedObject var status: Status

    var body: some View {
        ZStack(alignment: .topLeading) {
            WebHost(status: status).ignoresSafeArea()
            if !status.text.isEmpty && !status.ready {
                Text(status.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(6)
                    .padding(10)
            }
        }
        .background(Color(red: 0.086, green: 0.106, blue: 0.149))
    }
}

struct WebHost: UIViewRepresentable {
    let status: Status

    func makeCoordinator() -> Coordinator { Coordinator(status: status) }

    func makeUIView(context: Context) -> WKWebView {
        let c = context.coordinator
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(c.files, forURLScheme: "abandon")
        cfg.userContentController.add(c, name: "host")
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.uiDelegate = c
        w.navigationDelegate = c
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.scrollView.bounces = false
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.086, green: 0.106, blue: 0.149, alpha: 1)
        c.web = w
        Recorder.shared.onLevel = { [weak w] p in w?.evaluateJavaScript("window.recLevel&&recLevel(\(p))") }
        if c.files.find("/index.html") == nil {
            var info: String = c.files.diagnostics()
            info = info.replacingOccurrences(of: "<", with: "&lt;")
            let html: String = "<body style='background:#161b26;color:#eee;font:14px monospace;padding:20px'><h3>找不到界面资源 (index.html)</h3><pre>" + info + "</pre></body>"
            w.loadHTMLString(html, baseURL: nil)
            c.set("资源缺失：找不到 index.html")
        } else {
            w.load(URLRequest(url: URL(string: "abandon://local/index.html")!))
        }
        return w
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIDocumentPickerDelegate {
        let files = LocalFiles(root: Bundle.module.resourceURL!.appendingPathComponent("web"))
        let status: Status
        weak var web: WKWebView?
        var exporting = false

        init(status: Status) { self.status = status }

        func set(_ t: String) { DispatchQueue.main.async { self.status.text = t } }
        func clear() { DispatchQueue.main.async { self.status.text = ""; self.status.ready = true } }

        // MARK: 加载状态
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {}
        func webView(_ w: WKWebView, didCommit n: WKNavigation!) {}
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { clear() }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { set("加载失败：" + e.localizedDescription) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { set("加载失败：" + e.localizedDescription) }
        func webViewWebContentProcessDidTerminate(_ w: WKWebView) { set("网页进程已终止") }

        func top() -> UIViewController? {
            var vc = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
            while let p = vc?.presentedViewController { vc = p }
            return vc
        }

        // MARK: JS -> Swift
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let b = m.body as? [String: Any], let op = b["op"] as? String else { return }
            if op == "ready" {
                clear()
            } else if op == "open" {
                exporting = false
                let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
                p.delegate = self
                top()?.present(p, animated: true)
            } else if op == "share", let s = b["data"] as? String, let d = Data(base64Encoded: s) {
                let name: String = b["name"] as? String ?? "score"
                let tmp: URL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? d.write(to: tmp)
                let vc = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
                if let pop = vc.popoverPresentationController, let w = web {
                    pop.sourceView = w
                    pop.sourceRect = CGRect(x: w.bounds.midX, y: w.bounds.midY, width: 1, height: 1)
                    pop.permittedArrowDirections = []
                }
                top()?.present(vc, animated: true)
            } else if op == "rec" {
                let cb: Int = b["cb"] as? Int ?? 0
                Recorder.shared.handle(b["cmd"] as? String ?? "", b) { [weak self] out in
                    self?.web?.evaluateJavaScript("libResult(\(cb),\(Library.json(out)))")
                }
            } else if op == "lib" {
                let cb: Int = b["cb"] as? Int ?? 0
                let out: Any = Library.run(b["cmd"] as? String ?? "", b)
                web?.evaluateJavaScript("libResult(\(cb),\(Library.json(out)))")
            } else if op == "save", let s = b["data"] as? String, let d = Data(base64Encoded: s) {
                let name: String = b["name"] as? String ?? "score.gp"
                let tmp: URL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? d.write(to: tmp)
                exporting = true
                let p = UIDocumentPickerViewController(forExporting: [tmp], asCopy: true)
                p.delegate = self
                top()?.present(p, animated: true)
            }
        }

        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !exporting, let u = urls.first else { return }
            let ok: Bool = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: u) else { return }
            var name: String = u.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\")
            name = name.replacingOccurrences(of: "'", with: "\\'")
            web?.evaluateJavaScript("onOpen('\(name)','\(d.base64EncodedString())')")
        }

        // MARK: JS 弹窗
        func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage msg: String,
                     initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping () -> Void) {
            let a = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in done() })
            top()?.present(a, animated: true)
        }
        func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (String?) -> Void) {
            let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText }
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(nil) })
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in done(a.textFields?.first?.text) })
            top()?.present(a, animated: true)
        }
        func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage msg: String,
                     initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (Bool) -> Void) {
            let a = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(false) })
            a.addAction(UIAlertAction(title: "好", style: .default) { _ in done(true) })
            top()?.present(a, animated: true)
        }
    }
}
