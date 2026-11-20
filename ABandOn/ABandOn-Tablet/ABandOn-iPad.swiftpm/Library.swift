import Foundation
import WebKit

/// 资料库：App 自己管理的统一空间。结构 = 任意层级文件夹；
/// 默认“一首曲子 = 一个同名文件夹”，里面放 gp / gp5 / pdf 等谱子。
struct LibError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

enum Library {
    static let root: URL = {
        let fm = FileManager.default
        #if os(macOS)
        let base: URL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ABandOn")
        #else
        let base: URL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        let u: URL = base.appendingPathComponent("Library")
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func url(_ rel: String) -> URL? {
        var u: URL = root
        for part in rel.split(separator: "/") {
            let s = String(part)
            if s == ".." || s == "." { return nil }
            u.appendPathComponent(s)
        }
        return u
    }

    static func rel(_ u: URL) -> String {
        let a: String = u.resolvingSymlinksInPath().path
        let b: String = root.resolvingSymlinksInPath().path
        if a.count > b.count { return String(a.dropFirst(b.count + 1)) }
        return ""
    }

    static func clean(_ s: String) -> String {
        var t: String = s.replacingOccurrences(of: "/", with: "_")
        t = t.replacingOccurrences(of: ":", with: "_")
        return t
    }

    static func json(_ v: Any) -> String {
        let wrapped: [String: Any] = ["v": v]
        let d: Data = (try? JSONSerialization.data(withJSONObject: wrapped)) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    static func resolve(_ rel: String) throws -> URL {
        guard let u = url(rel) else { throw LibError(msg: "路径无效") }
        return u
    }

    static func run(_ cmd: String, _ a: [String: Any]) -> Any {
        let fm = FileManager.default
        let path: String = a["path"] as? String ?? ""
        do {
            switch cmd {
            case "list":
                let u: URL = try resolve(path)
                let items: [URL] = try fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey])
                var out: [[String: Any]] = []
                for i in items where !i.lastPathComponent.hasPrefix(".") {
                    let v = try? i.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey])
                    var e: [String: Any] = [:]
                    e["name"] = i.lastPathComponent
                    e["dir"] = v?.isDirectory ?? false
                    e["size"] = v?.fileSize ?? 0
                    let created: Double = v?.creationDate?.timeIntervalSince1970 ?? 0
                    e["created"] = created * 1000
                    out.append(e)
                }
                return out
            case "tree":
                var out: [String] = [""]
                if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for case let u as URL in en {
                        let isDir: Bool = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        if isDir { out.append(rel(u)) }
                    }
                }
                return out.sorted()
            case "read":
                let u: URL = try resolve(path)
                return try Data(contentsOf: u).base64EncodedString()
            case "write":
                let u: URL = try resolve(path)
                guard let s = a["data"] as? String, let d = Data(base64Encoded: s) else { throw LibError(msg: "数据无效") }
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: u)
                return true
            case "import":
                let dir: String = a["dir"] as? String ?? ""
                let name: String = clean(a["name"] as? String ?? "未命名.gp")
                guard let s = a["data"] as? String, let d = Data(base64Encoded: s) else { throw LibError(msg: "数据无效") }
                let base: String = (name as NSString).deletingPathExtension
                let folder: URL = try resolve(dir).appendingPathComponent(base)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let f: URL = folder.appendingPathComponent(name)
                try d.write(to: f)
                return rel(f)
            case "mkdir":
                let u: URL = try resolve(path)
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                return true
            case "rename":
                let u: URL = try resolve(path)
                let n: String = clean(a["newName"] as? String ?? "")
                if n.isEmpty { throw LibError(msg: "名称不能为空") }
                let dst: URL = u.deletingLastPathComponent().appendingPathComponent(n)
                if fm.fileExists(atPath: dst.path) { throw LibError(msg: "已存在同名项目") }
                try fm.moveItem(at: u, to: dst)
                return true
            case "move":
                let u: URL = try resolve(path)
                let destDir: URL = try resolve(a["dest"] as? String ?? "")
                let dst: URL = destDir.appendingPathComponent(u.lastPathComponent)
                if dst.path.hasPrefix(u.path + "/") || dst.path == u.path { throw LibError(msg: "不能移动到自身内部") }
                if fm.fileExists(atPath: dst.path) { throw LibError(msg: "目标位置已有同名项目") }
                try fm.moveItem(at: u, to: dst)
                return true
            case "delete":
                let u: URL = try resolve(path)
                if u == root { throw LibError(msg: "不能删除根目录") }
                try fm.removeItem(at: u)
                return true
            default:
                return ["err": "未知命令"]
            }
        } catch {
            return ["err": error.localizedDescription]
        }
    }
}

/// abandon://local/... 提供 App 内置 web 资源；abandon://local/lib/... 提供资料库文件（PDF 预览用）
final class LocalFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    /// 兜底索引：Playgrounds 可能把资源打平或放在别的目录，按文件名在 App 包里找
    private lazy var index: [String: URL] = {
        var d: [String: URL] = [:]
        if let en = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in en {
                let isDir: Bool = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDir && d[u.lastPathComponent] == nil { d[u.lastPathComponent] = u }
            }
        }
        return d
    }()

    func find(_ path: String) -> URL? {
        let rel: String = String(path.dropFirst())
        let direct: URL = root.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return index[(rel as NSString).lastPathComponent]
    }

    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("root: " + root.path)
        lines.append("root exists: " + String(FileManager.default.fileExists(atPath: root.path)))
        lines.append("bundle: " + Bundle.main.bundlePath)
        var n: Int = 0
        if let en = FileManager.default.enumerator(atPath: Bundle.main.bundlePath) {
            for case let p as String in en {
                lines.append(p)
                n += 1
                if n >= 80 { break }
            }
        }
        return lines.joined(separator: "\n")
    }

    static let mimes: [String: String] = [
        "html": "text/html", "js": "text/javascript", "css": "text/css",
        "woff": "font/woff", "woff2": "font/woff2", "otf": "font/otf",
        "svg": "image/svg+xml", "json": "application/json",
        "pdf": "application/pdf", "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg"
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path: String = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        var file: URL? = nil
        if path.hasPrefix("/lib/") {
            file = Library.url(String(path.dropFirst(5)))
        } else if !path.contains("..") {
            file = find(path)
        }
        guard let f = file, let data = try? Data(contentsOf: f) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            task.didReceive(r); task.didFinish(); return
        }
        var h: [String: String] = [:]
        h["Content-Type"] = LocalFiles.mimes[f.pathExtension.lowercased()] ?? "application/octet-stream"
        h["Content-Length"] = String(data.count)
        h["Access-Control-Allow-Origin"] = "*"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: h)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
