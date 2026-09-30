import SwiftUI
import SwiftData
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - The web view LifeTracker keeps for the university portal

/// Owns one WKWebView and publishes what the toolbar needs. The login is kept
/// in the normal (persistent) website store, so you stay signed in between
/// launches — exactly like a browser tab that lives inside the app.
final class PortalWeb: NSObject, ObservableObject,
                       WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    static let shared = PortalWeb()

    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = ""
    @Published var currentURL: URL?
    @Published var lastError: String?

    /// A file the portal just downloaded, waiting to be filed into a subject.
    @Published var finishedDownload: DownloadedFile?
    @Published var downloadName: String?
    @Published var downloadProgress: Double = 0

    /// True while the page on screen is a document (PDF, PPT preview…) rather
    /// than a normal HTML page — so the toolbar can offer "save this file".
    @Published var viewingDocument = false

    /// Set when you tap a login box on the portal: the app then offers the
    /// saved accounts in a strip over the page.
    @Published var offeringAutofill = false
    /// Cleared on every navigation — dismissing the strip only hides it for
    /// the page you're on.
    @Published var autofillDismissed = false

    struct DownloadedFile: Identifiable {
        let id = UUID()
        let url: URL          // temporary file on disk
        let name: String      // "Module_III_LLM_and_Diffusion_Models"
        let ext: String       // "pdf"
        var size: Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0 }
    }

    private var observers: [NSKeyValueObservation] = []
    private var progressObserver: NSKeyValueObservation?
    private var destinations: [ObjectIdentifier: URL] = [:]

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()            // keeps cookies → stays logged in
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: PortalWeb.bridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(self, name: "lifetracker")

        webView.navigationDelegate = self
        webView.uiDelegate = self                        // ← this is what makes JUNO's buttons work
        #if os(iOS)
        webView.allowsBackForwardNavigationGestures = true
        #endif
        observers = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.canGoBack = v.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.canGoForward = v.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.isLoading = v.isLoading }
            },
            webView.observe(\.title, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.pageTitle = v.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] v, _ in
                Task { @MainActor in self?.currentURL = v.url }
            },
        ]
    }

    func loadHome(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        if webView.url == nil { webView.load(URLRequest(url: url)) }
    }

    func go(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }
    func reload() { webView.reload() }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }

    /// Signs out of the portal by clearing its cookies and cache.
    /// Clears the cookies for the portal's own host, not the whole store.
    func clearSession(host: String? = nil) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let all = await WKWebsiteDataStore.default().dataRecords(ofTypes: types)
        let records: [WKWebsiteDataRecord]
        if let host, !host.isEmpty {
            // Match the host itself and its sub/parent domains — not a guessed
            // "last two labels", which would treat every *.ac.in as one site.
            records = all.filter {
                $0.displayName == host
                    || host.hasSuffix("." + $0.displayName)
                    || $0.displayName.hasSuffix("." + host)
            }
        } else {
            records = all
        }
        await WKWebsiteDataStore.default().removeData(ofTypes: types, for: records)
    }

    /// The page you're looking at, as PDF bytes.
    @MainActor
    func pdf() async throws -> Data {
        try await webView.pdf()
    }

    // MARK: Pop-ups (JUNO opens its files with window.open / target="_blank")

    /// WebKit asks for a brand-new window here. LifeTracker has no second
    /// window, so without this method the click does *nothing at all* — which
    /// is exactly what the download buttons were doing. Loading the request in
    /// the same web view lets the normal download rules below take over.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.request.url != nil else { return nil }
        if navigationAction.shouldPerformDownload {
            webView.startDownload(using: navigationAction.request) { download in
                download.delegate = self
            }
        } else {
            webView.load(navigationAction.request)
        }
        return nil
    }


    /// macOS only: a web page's "choose a file" button does nothing unless the
    /// app puts up the open panel itself. This is what makes GitHub's
    /// "Upload a photo…" (and any other file input) work.
    #if os(macOS)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    #endif

    // JUNO shows confirm()/alert() dialogs on some pages; without these the
    // JavaScript thread stalls and the page appears frozen.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await MainActor.run { self.lastError = message }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool { true }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { defaultText }

    // MARK: Downloads

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Links marked as downloads (the ⤓ buttons in JUNO).
        if navigationAction.shouldPerformDownload { return (.download, preferences) }

        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        let mime = (navigationResponse.response.mimeType ?? "").lowercased()

        // Anything the portal sends as an attachment, or that a web view can't
        // display (zip, docx, pptx…), becomes a download instead of a blank page.
        if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
            return .download
        }
        if navigationResponse.isForMainFrame {
            let isDoc = mime.contains("pdf")
            await MainActor.run { self.viewingDocument = isDoc }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortalDownloads/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        await MainActor.run {
            downloadName = url.lastPathComponent
            downloadProgress = 0
            progressObserver = download.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                Task { @MainActor in self.downloadProgress = p.fractionCompleted }
            }
        }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) ?? download.progress.fileURL else { return }
        Task { @MainActor in
            progressObserver = nil
            downloadName = nil
            downloadProgress = 0
            finishedDownload = DownloadedFile(url: url,
                                              name: url.deletingPathExtension().lastPathComponent,
                                              ext: url.pathExtension)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        Task { @MainActor in
            progressObserver = nil
            downloadName = nil
            downloadProgress = 0
            lastError = "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: The JavaScript bridge

    /// Runs on every page the portal loads. It does three things:
    /// 1. sends `window.open` back into this same web view (so pop-up buttons work),
    /// 2. rewrites `target="_blank"` links and forms to open in place,
    /// 3. catches `blob:` / `data:` downloads — the kind a page builds in memory,
    ///    which WebKit can't download by itself — and hands the bytes to Swift.
    private static let bridgeScript = """
    (function () {
      if (window.__ltPortalHooked) { return; }
      window.__ltPortalHooked = true;

      function send(payload) {
        try { window.webkit.messageHandlers.lifetracker.postMessage(payload); } catch (e) {}
      }

      function grab(href, name) {
        send({ kind: 'downloadStarted', name: name || '' });
        fetch(href).then(function (r) { return r.blob(); }).then(function (blob) {
          var reader = new FileReader();
          reader.onload = function () {
            var s = String(reader.result);
            var comma = s.indexOf(',');
            send({ kind: 'file',
                   name: name || 'download',
                   mime: blob.type || '',
                   base64: comma >= 0 ? s.slice(comma + 1) : '' });
          };
          reader.onerror = function () { send({ kind: 'error', message: 'Could not read that file.' }); };
          reader.readAsDataURL(blob);
        }).catch(function (e) {
          send({ kind: 'error', message: 'Download blocked by the page: ' + e });
        });
      }

      var nativeOpen = window.open;
      window.open = function (u, n, f) {
        try {
          if (!u) { return nativeOpen.apply(window, arguments); }
          var abs = new URL(u, document.baseURI).href;
          if (abs.indexOf('blob:') === 0 || abs.indexOf('data:') === 0) { grab(abs, null); return null; }
          window.location.href = abs;
          return null;
        } catch (e) { return nativeOpen.apply(window, arguments); }
      };

      document.addEventListener('click', function (e) {
        var a = e.target && e.target.closest ? e.target.closest('a') : null;
        if (!a) { return; }
        var href = a.getAttribute('href');
        if (!href || href.indexOf('javascript:') === 0) { return; }
        var abs;
        try { abs = new URL(href, document.baseURI).href; } catch (err) { return; }
        if (abs.indexOf('blob:') === 0 || abs.indexOf('data:') === 0) {
          e.preventDefault();
          grab(abs, a.getAttribute('download') || a.textContent.trim());
          return;
        }
        // Keep the download attribute intact, just stop it asking for a new window.
        if (a.target && a.target !== '_self') { a.target = '_self'; }
      }, true);

      document.addEventListener('submit', function (e) {
        var f = e.target;
        if (f && f.target && f.target !== '_self') { f.target = '_self'; }
      }, true);

      // Tell the app when you tap a sign-in box, so it can offer the saved
      // ID and password right there instead of making you open a sheet.
      function isSignInField(el) {
        if (!el || el.tagName !== 'INPUT') { return false; }
        var t = (el.type || '').toLowerCase();
        if (t === 'password') { return true; }
        if (t && t !== 'text' && t !== 'email' && t !== 'tel') { return false; }
        if (!document.querySelector('input[type=password]')) { return false; }
        var hay = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '') + ' '
                   + (el.getAttribute('autocomplete') || '')).toLowerCase();
        return /user|login|email|prn|roll|enrol|uname|account|\\bid\\b/.test(hay) || true;
      }
      document.addEventListener('focusin', function (e) {
        if (isSignInField(e.target)) { send({ kind: 'loginFocus' }); }
      }, true);

      // Some viewers revoke their blob right after creating it; keep a copy of
      // the last one so the toolbar's "save the file on screen" still works.
      var createURL = URL.createObjectURL;
      URL.createObjectURL = function (obj) {
        var u = createURL.call(URL, obj);
        window.__ltLastBlob = u;
        return u;
      };
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "loginFocus":
            Task { @MainActor in
                guard !autofillDismissed else { return }
                withAnimation(.easeOut(duration: 0.18)) { offeringAutofill = true }
            }
        case "downloadStarted":
            Task { @MainActor in
                downloadName = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Downloading…"
                downloadProgress = 0
            }
        case "error":
            Task { @MainActor in
                downloadName = nil
                lastError = body["message"] as? String
            }
        case "file":
            let raw = (body["name"] as? String) ?? "download"
            let mime = (body["mime"] as? String) ?? ""
            guard let base64 = body["base64"] as? String, let data = Data(base64Encoded: base64) else {
                Task { @MainActor in
                    downloadName = nil
                    lastError = "That file came through empty."
                }
                return
            }
            Task { @MainActor in deliver(data: data, suggestedName: raw, mime: mime) }
        default:
            break
        }
    }

    /// Puts bytes on disk and raises the "save into a subject" sheet.
    @MainActor
    func deliver(data: Data, suggestedName: String, mime: String) {
        let cleaned = PortalWeb.sanitize(suggestedName)
        var ext = (cleaned as NSString).pathExtension
        if ext.isEmpty { ext = PortalWeb.fileExtension(forMIME: mime) }
        let base = ext.isEmpty ? cleaned : (cleaned as NSString).deletingPathExtension
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortalDownloads/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        do {
            try data.write(to: url)
            downloadName = nil
            downloadProgress = 0
            finishedDownload = DownloadedFile(url: url,
                                              name: base.isEmpty ? "download" : base,
                                              ext: ext.isEmpty ? "dat" : ext)
        } catch {
            downloadName = nil
            lastError = "Couldn't keep that file: \(error.localizedDescription)"
        }
    }

    /// Last resort: fetch whatever URL the web view is showing, using the
    /// portal's own cookies. This is how a PDF that opened *inside* the viewer
    /// still ends up in a subject.
    @MainActor
    func downloadCurrentPage() async {
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else {
            lastError = "There's no file on screen to save."
            return
        }
        downloadName = url.lastPathComponent.isEmpty ? "Downloading…" : url.lastPathComponent
        downloadProgress = 0
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let host = url.host ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        var request = URLRequest(url: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let suggested = response.suggestedFilename ?? url.lastPathComponent
            deliver(data: data,
                    suggestedName: suggested.isEmpty ? "download" : suggested,
                    mime: response.mimeType ?? "")
        } catch {
            downloadName = nil
            lastError = "Couldn't fetch that file: \(error.localizedDescription)"
        }
    }

    @MainActor
    func autofill(_ account: PortalAccount) async -> Bool {
        let ok = await autofill(username: account.username, password: account.password)
        offeringAutofill = false
        return ok
    }

    /// Fills the portal's sign-in form with the saved ID and password.
    @MainActor
    func autofill(username: String, password: String) async -> Bool {
        let u = PortalWeb.jsString(username)
        let p = PortalWeb.jsString(password)
        let js = """
        (function () {
          var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          function put(el, v) {
            if (!el) { return 0; }
            setter.call(el, v);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 1;
          }
          var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));
          var visible = inputs.filter(function (i) { return !i.disabled && i.type !== 'hidden' && i.offsetParent !== null; });
          var pass = visible.filter(function (i) { return i.type === 'password'; })[0];
          var user = visible.filter(function (i) { return i.type === 'text' || i.type === 'email' || i.type === 'tel' || i.type === ''; })[0];
          return put(user, \(u)) + put(pass, \(p));
        })();
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, _ in
                let filled = (value as? NSNumber)?.intValue ?? 0
                continuation.resume(returning: filled > 0)
            }
        }
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }

    private static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : String(cleaned.prefix(120))
    }

    private static func fileExtension(forMIME mime: String) -> String {
        let m = mime.lowercased().components(separatedBy: ";").first ?? ""
        switch m {
        case "application/pdf": return "pdf"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.ms-excel": return "xls"
        case "application/zip", "application/x-zip-compressed": return "zip"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "video/mp4": return "mp4"
        default: return ""
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            viewingDocument = false
            offeringAutofill = false
            autofillDismissed = false
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Cancelled navigations are normal (a link we turned into a download).
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              nsError.code != 102 else { return }
        Task { @MainActor in lastError = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in lastError = nil }
    }
}

/// SwiftUI wrapper — same WKWebView on Mac and iPad.
/// The web view is handed to SwiftUI inside a plain container rather than on
/// its own: a WKWebView left to itself will claim the size of its whole page
/// and push the app's own toolbar and sidebar out of the window. The container
/// pins it to the frame it's given and masks anything that overflows.
struct PortalWebView {
    @ObservedObject var model: PortalWeb

    fileprivate func install(into container: PlatformView) {
        let web = model.webView
        if web.superview === container, container.subviews.count == 1 { return }

        // Take out whichever site was showing before.
        for old in container.subviews where old !== web { old.removeFromSuperview() }
        if web.superview !== container {
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                web.topAnchor.constraint(equalTo: container.topAnchor),
                web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        // A web view will happily claim the size of its whole page. Told to
        // hug nothing and resist nothing, it takes the frame it is given
        // instead of pushing the app's own layout out of the window.
        PortalWebView.relax(web)
        PortalWebView.relax(container)
    }

    fileprivate static func relax(_ view: PlatformView) {
        #if os(macOS)
        let axes: [NSLayoutConstraint.Orientation] = [.horizontal, .vertical]
        #else
        let axes: [NSLayoutConstraint.Axis] = [.horizontal, .vertical]
        #endif
        for axis in axes {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.init(1), for: axis)
        }
    }
}

#if os(macOS)
typealias PlatformView = NSView

extension PortalWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        // AppKit renders the web view into its own layer tree, which SwiftUI's
        // .clipped() doesn't mask — this is what let the page paint over the
        // app's toolbar.
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        install(into: container)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) { install(into: nsView) }
}
#else
typealias PlatformView = UIView

extension PortalWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        install(into: container)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) { install(into: uiView) }
}
#endif

// MARK: - University page

struct UniversityView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.layoutWidth) private var width
    @ObservedObject private var web = PortalWeb.shared
    @ObservedObject private var keys = PortalKeys.shared

    private var siteHome: String { homeURL }
    /// LifeTracker's own name for the portal — never the page's <title>, which
    /// is where "Welcome to DYP IU" came from.
    private var siteTitle: String { portalName }

    @AppStorage("portal.homeURL") private var homeURL: String = "https://erp.dypiu.ac.in/login.htm"
    @AppStorage("portal.name") private var portalName: String = "JUNO — DYPIU"

    @State private var savingPDF = false
    @State private var pdfToSave: Data?
    @State private var manualDownloadHint = false
    @State private var confirmSignOut = false
    @State private var editingHome = false
    @State private var draftHome = ""
    @State private var showKeys = false
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Palette.hairline)
            ZStack(alignment: .bottom) {
                PortalWebView(model: web)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                if web.offeringAutofill && !keys.accounts.isEmpty {
                    autofillStrip
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let error = web.lastError {
                    errorBar(error)
                }
                if let toast {
                    Text(toast)
                        .font(.mono(12))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Palette.callout, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline))
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Palette.surface)
        .navigationTitle("University")
        .blendedToolbar()
        .onAppear { web.loadHome(siteHome) }
        // Saving the page itself as PDF
        .sheet(item: Binding(get: { pdfToSave.map { PDFPayload(data: $0) } },
                             set: { if $0 == nil { pdfToSave = nil } })) { payload in
            SaveToSubjectSheet(source: .data(payload.data), suggestedName: suggestedName, ext: "pdf") { message in
                show(message)
            }
        }
        // A file the portal downloaded (PPT, PDF, zip…) — goes straight into a subject
        .sheet(item: Binding(get: { web.finishedDownload },
                             set: { web.finishedDownload = $0 })) { file in
            SaveToSubjectSheet(source: .file(file.url), suggestedName: file.name, ext: file.ext) { message in
                show(message)
            }
        }
        .sheet(isPresented: $showKeys) {
            PortalKeysSheet(portalName: siteTitle, web: web) { message in show(message) }
        }
        .alert("Downloads", isPresented: $manualDownloadHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("""
            Anything you download here (PDF, PPT, Word, zip…) is caught by LifeTracker and offered straight to a subject's Files — it never goes to your Downloads folder.

            If a file opens in the viewer instead of downloading, use “Save the file on screen” in the ⋯ menu.
            """)
        }
        .alert("Sign out of \(siteTitle)?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                Task {
                    await web.clearSession(host: URL(string: siteHome)?.host)
                    web.go(to: siteHome)
                    show("Signed out of \(siteTitle)")
                }
            }
        } message: {
            Text("This clears that site's cookies on this device. The other site, and your LifeTracker data, aren't affected.")
        }
        .sheet(isPresented: $editingHome) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Portal address").font(.mono(15, .bold))
                Text("The page LifeTracker opens for your university.")
                    .font(.caption).foregroundStyle(Palette.mutedText)
                TextField("https://…", text: $draftHome)
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(12))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                FormTextField("Name", text: $portalName)
                HStack {
                    Spacer()
                    Button("Cancel") { editingHome = false }
                    Button("Save") {
                        if let url = LinkTools.normalize(draftHome) {
                            homeURL = url.absoluteString
                            web.go(to: homeURL)
                        }
                        editingHome = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .sheetFrame(width: 460, height: 260)
        }
    }

    // MARK: Autofill strip

    /// Appears over the page the moment you tap a sign-in box. One tap on a
    /// name fills both boxes; the copy button is there for the odd field the
    /// page won't let anyone type into.
    private var autofillStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.accent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(keys.accounts) { account in
                        HStack(spacing: 0) {
                            Button {
                                Task { @MainActor in
                                    let ok = await web.autofill(account)
                                    show(ok ? "Filled \(account.display)" : "No sign-in boxes found on this page")
                                }
                            } label: {
                                Text(account.display)
                                    .font(.mono(12, .medium))
                                    .lineLimit(1)
                                    .padding(.leading, 10).padding(.trailing, 6)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Fill the ID and password for \(account.display)")

                            Button {
                                Platform.copy(account.password)
                                show("Password copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .padding(.trailing, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy just the password")
                        }
                        .background(Palette.elevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline))
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: 320)

            Button {
                showKeys = true
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Manage saved logins")

            Button {
                withAnimation {
                    web.offeringAutofill = false
                    web.autofillDismissed = true
                }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.mutedText)
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.callout, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }

    // MARK: Toolbar

    private var compact: Bool { AppLayout.isCompact(width) }

    @MainActor
    private var toolbar: some View {
        HStack(spacing: 10) {
            Group {
                Button { web.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!web.canGoBack)
                Button { web.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!web.canGoForward)
                Button { web.reload() } label: {
                    Image(systemName: web.isLoading ? "xmark" : "arrow.clockwise")
                }
                Button { web.go(to: siteHome) } label: { Image(systemName: "house") }
                    .help("Back to \(siteTitle)")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(siteTitle)
                    .font(.mono(12, .semibold))
                    .lineLimit(1)
                if !compact {
                    Text(web.currentURL?.host ?? "")
                        .font(.mono(10))
                        .foregroundStyle(Palette.mutedText)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)

            if web.isLoading { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)

            // Live download progress from the portal
            if let name = web.downloadName {
                HStack(spacing: 6) {
                    ProgressView(value: web.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                    if !compact {
                        Text(name).font(.mono(10)).lineLimit(1).frame(maxWidth: 140)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Palette.callout, in: Capsule())
            }

            // Saved ID & password, one tap from the login page
            Button {
                showKeys = true
            } label: {
                if compact {
                    Image(systemName: "key.fill")
                } else {
                    Label("ID & Pass", systemImage: "key.fill")
                }
            }
            .help("Your saved \(siteTitle) ID and password — copy or fill them in")

            Button {
                savePDF()
            } label: {
                if savingPDF {
                    ProgressView().controlSize(.small)
                } else if compact {
                    Image(systemName: "square.and.arrow.down")
                } else {
                    Label("Save page", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(savingPDF)
            .help("Save this page as a PDF in your study materials")

            Menu {
                Button {
                    Task { @MainActor in await web.downloadCurrentPage() }
                } label: {
                    Label("Save the file on screen", systemImage: "arrow.down.doc")
                }
                Button("Open in browser") { if let u = web.currentURL ?? URL(string: siteHome) { openURL(u) } }
                Button("Where do downloads go?") { manualDownloadHint = true }
                Button("Copy link") { Platform.copy((web.currentURL?.absoluteString ?? siteHome)) }
                Divider()
                Button("Change portal address…") {
                    draftHome = siteHome
                    editingHome = true
                }
                Button("Sign out of \(siteTitle)", role: .destructive) { confirmSignOut = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .frame(width: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.sidebar)
    }

    private func errorBar(_ message: String) -> some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.mono(11))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.callout, in: Capsule())
            .padding(.bottom, 16)
    }

    private var suggestedName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let title = web.pageTitle.isEmpty ? siteTitle : web.pageTitle
        return "\(title) \(f.string(from: .now))"
    }

    private func savePDF() {
        savingPDF = true
        Task { @MainActor in
            do {
                pdfToSave = try await web.pdf()
            } catch {
                // A PDF already open in the viewer can't be re-printed — fetch it instead.
                await web.downloadCurrentPage()
            }
            savingPDF = false
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { toast = nil }
        }
    }
}

private struct PDFPayload: Identifiable {
    let id = UUID()
    let data: Data
}

// MARK: - Saved portal ID & password

/// One saved portal login. You can keep as many as you like — a student
/// account, a parent portal, a second university login…
struct PortalAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String = ""
    var username: String = ""
    var password: String = ""

    /// What the chip in the autofill strip says.
    var display: String {
        if !label.isEmpty { return label }
        if !username.isEmpty { return username }
        return "Saved login"
    }
}

/// Kept in the system Keychain, never in the app's database and never in an
/// export file — so a shared `.lifetracker` archive can't leak your login.
final class PortalKeys: ObservableObject {
    static let shared = PortalKeys()

    @Published private(set) var accounts: [PortalAccount] = []

    private static let listKey = "portal.accounts"

    private init() {
        load()
        migrateSingleAccount()
    }

    var isEmpty: Bool { accounts.isEmpty }

    private func load() {
        guard let raw = Keychain.get(Self.listKey), let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PortalAccount].self, from: data) else { return }
        accounts = decoded
    }

    /// Re-reads the Keychain — used after an import brings logins across.
    func reload() {
        accounts = []
        load()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts),
              let text = String(data: data, encoding: .utf8) else { return }
        Keychain.set(accounts.isEmpty ? nil : text, for: Self.listKey)
    }

    /// Picks up the single ID/password an earlier build stored.
    private func migrateSingleAccount() {
        guard accounts.isEmpty else { return }
        let user = Keychain.get("portal.username") ?? ""
        let pass = Keychain.get("portal.password") ?? ""
        guard !user.isEmpty || !pass.isEmpty else { return }
        accounts = [PortalAccount(label: Keychain.get("portal.note") ?? "", username: user, password: pass)]
        persist()
        Keychain.set(nil, for: "portal.username")
        Keychain.set(nil, for: "portal.password")
        Keychain.set(nil, for: "portal.note")
    }

    func save(_ account: PortalAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    func remove(_ account: PortalAccount) {
        accounts.removeAll { $0.id == account.id }
        persist()
    }
}

private struct PortalKeysSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keys = PortalKeys.shared

    let portalName: String
    /// Whichever site the page is showing, so Fill types into the right one.
    @ObservedObject var web: PortalWeb
    var onMessage: (String) -> Void

    @State private var editing: PortalAccount?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(portalName) logins").font(.mono(15, .bold))
            Text("Saved in this device's Keychain — not in your database, and never written into an export file. Tap a sign-in box on the portal and these appear right there.")
                .font(.caption).foregroundStyle(Palette.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            if keys.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 26, weight: .light))
                    Text("No logins saved yet").font(.mono(13, .semibold))
                    Text("Add your ID and password once and never type them again.")
                        .font(.mono(11)).foregroundStyle(Palette.mutedText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(keys.accounts) { account in
                            row(account)
                        }
                    }
                }
            }

            if let copied {
                Label("\(copied) copied", systemImage: "checkmark.circle.fill")
                    .font(.mono(11))
                    .foregroundStyle(Palette.accent)
            }

            HStack(spacing: 10) {
                Button {
                    editing = PortalAccount()
                } label: {
                    Label("Add a login", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .sheetFrame(width: 520, height: 460)
        .sheet(item: $editing) { account in
            PortalAccountEditor(account: account) { saved in
                keys.save(saved)
                onMessage("Login saved")
            }
        }
    }

    private func row(_ account: PortalAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key")
                .foregroundStyle(Palette.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.display).font(.mono(13, .semibold)).lineLimit(1)
                Text(account.username.isEmpty ? "no ID saved" : account.username)
                    .font(.mono(11)).foregroundStyle(Palette.mutedText).lineLimit(1)
            }
            Spacer(minLength: 6)

            Button {
                Task { @MainActor in
                    let ok = await web.autofill(account)
                    dismiss()
                    onMessage(ok ? "Filled \(account.display)" : "No sign-in boxes on this page")
                }
            } label: {
                Label("Fill", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Type this ID and password into the portal")

            copyButton("ID", value: account.username, icon: "person")
            copyButton("Password", value: account.password, icon: "key")

            Button {
                editing = account
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.mutedText)
                .help("Edit")

            Button(role: .destructive) {
                keys.remove(account)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.mutedText)
                .help("Delete this login")
        }
        .padding(10)
        .background(Palette.callout, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    private func copyButton(_ label: String, value: String, icon: String) -> some View {
        Button {
            Platform.copy(value)
            withAnimation { copied = label }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation { if copied == label { copied = nil } }
            }
        } label: {
            Image(systemName: icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(value.isEmpty)
        .help("Copy \(label.lowercased())")
    }
}

/// Add or edit one saved login.
private struct PortalAccountEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State var account: PortalAccount
    var onSave: (PortalAccount) -> Void

    @State private var reveal = false

    init(account: PortalAccount, onSave: @escaping (PortalAccount) -> Void) {
        _account = State(initialValue: account)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(account.username.isEmpty ? "New login" : "Edit login")
                .font(.mono(15, .bold))

            FormTextField("Name (e.g. JUNO student)", text: $account.label)

            VStack(alignment: .leading, spacing: 5) {
                Text("ID / PRN").font(.mono(10, .semibold)).foregroundStyle(Palette.mutedText)
                TextField("20244723", text: $account.username)
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(12))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Password").font(.mono(10, .semibold)).foregroundStyle(Palette.mutedText)
                HStack(spacing: 6) {
                    Group {
                        if reveal {
                            TextField("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}", text: $account.password)
                        } else {
                            SecureField("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}", text: $account.password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(12))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    Button {
                        reveal.toggle()
                    } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .help(reveal ? "Hide" : "Show")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var cleaned = account
                    cleaned.label = cleaned.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.username = cleaned.username.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(cleaned)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(account.username.isEmpty && account.password.isEmpty)
            }
        }
        .padding(20)
        .sheetFrame(width: 440, height: 340)
    }
}

// MARK: - Save the page into a subject

private struct SaveToSubjectSheet: View {
    enum Source {
        case data(Data)
        case file(URL)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \StudySubject.sortIndex) private var subjects: [StudySubject]

    let source: Source
    let suggestedName: String
    let ext: String
    var onSaved: (String) -> Void

    @State private var name = ""
    @State private var subjectID: UUID?
    @State private var newSubjectName = "University"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isDownload ? "Save download to study materials" : "Save page to study materials")
                .font(.mono(15, .bold))
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) · \(ext.uppercased())")
                .font(.caption).foregroundStyle(Palette.mutedText)

            FormTextField("File name", text: $name)

            if subjects.isEmpty {
                FormTextField("New subject", text: $newSubjectName)
                Text("You have no subjects yet — this one will be created for you.")
                    .font(.caption).foregroundStyle(Palette.mutedText)
            } else {
                Picker("Subject", selection: $subjectID) {
                    ForEach(subjects) { s in
                        Text("\(s.emoji)  \(s.name)").tag(s.id as UUID?)
                    }
                }
            }

            HStack {
                Button {
                    ShareTools.share([tempFile()])
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Send this file straight to WhatsApp, AirDrop, Mail…")
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .sheetFrame(width: 460, height: 300)
        .onAppear {
            name = suggestedName
            subjectID = subjects.first?.id
        }
    }

    private var isDownload: Bool { if case .file = source { return true }; return false }

    private var byteCount: Int {
        switch source {
        case .data(let d): return d.count
        case .file(let url): return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        }
    }

    private func bytes() -> Data? {
        switch source {
        case .data(let d): return d
        case .file(let url): return try? Data(contentsOf: url)
        }
    }

    private func tempFile() -> URL {
        switch source {
        case .file(let url): return url
        case .data(let d):
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name.isEmpty ? "page" : name).\(ext)")
            try? d.write(to: url)
            return url
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let data = bytes() else {
            onSaved("Couldn't read that file")
            dismiss()
            return
        }
        let subject: StudySubject
        if let id = subjectID, let found = subjects.first(where: { $0.id == id }) {
            subject = found
        } else {
            subject = StudySubject(name: newSubjectName.isEmpty ? "University" : newSubjectName,
                                   emoji: "🎓", colorHex: StudyPalette.swatches[1],
                                   sortIndex: (subjects.map(\.sortIndex).max() ?? -1) + 1)
            context.insert(subject)
        }
        let material = StudyMaterial(fileName: trimmed, fileExtension: ext, data: data, subject: subject)
        context.insert(material)
        try? context.save()
        Task {
            await DriveSync.shared.backup(material)      // also lands in Drive if connected
            try? context.save()
        }
        // The download's temporary copy isn't needed once it's in the app.
        if case .file(let url) = source {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        onSaved("Saved “\(trimmed).\(ext)” to \(subject.name)")
        dismiss()
    }
}

/// Shared link cleanup (also used by the Links tab).
enum LinkTools {
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let hasScheme = s.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
        if !hasScheme { s = "https://" + s }
        return URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlAllowedForLinks) ?? s)
    }
}
