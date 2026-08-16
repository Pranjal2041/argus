import AppKit
import Foundation
import Network
import WebKit

// MARK: - Agent browser provider

/// The optional browser.v1 provider hosted by Argus. The Go broker only discovers
/// and relays this loopback service; all browser state and WebKit work remains here.
@MainActor
final class BrowserControlService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var providerPort: UInt16?

    private weak var dashboards: DashboardsModel?
    private weak var appState: AppState?
    private var listener: BrowserLoopbackServer?
    private var heartbeat: Timer?
    private var hiddenTabs: [UUID: BrowserManagedTab] = [:]
    private var managedTabs: [UUID: BrowserManagedTab] = [:]
    private var ownedTabIDs: Set<UUID> = []
    private var rpcBusy = false
    private var rpcWaiters: [CheckedContinuation<Void, Never>] = []
    private let nativeInputEnabled: Bool
    private let browserHostName: String

    init(nativeInputEnabled: Bool = true) {
        self.nativeInputEnabled = nativeInputEnabled
        browserHostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func start(dashboards: DashboardsModel, state: AppState) {
        self.dashboards = dashboards
        self.appState = state
        guard listener == nil else { return }
        let server = BrowserLoopbackServer { [weak self] body in
            guard let self else { return BrowserHTTPResponse.serviceUnavailable }
            return await self.handleRPC(body)
        }
        listener = server
        server.start { [weak self] port in
            Task { @MainActor in
                guard let self else { return }
                self.providerPort = port
                self.isRunning = true
                await self.registerProvider()
                self.startHeartbeat()
            }
        }
    }

    /// Direct protocol seam used by the WebKit integration tests. Production
    /// requests enter through the loopback server and execute the same handler.
    func bindForTesting(dashboards: DashboardsModel) {
        self.dashboards = dashboards
    }

    func processRPCForTesting(_ body: Data) async -> Data {
        await handleRPC(body).body
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.registerProvider() }
        }
    }

    private func registerProvider() async {
        guard let providerPort else { return }
        guard let url = URL(string: "http://127.0.0.1:8722/browser/provider") else { return }
        let payload: [String: Any] = [
            "port": Int(providerPort),
            "version": 1,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "provider": "Argus"
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        _ = try? await URLSession.shared.data(for: request)
    }

    private func handleRPC(_ body: Data) async -> BrowserHTTPResponse {
        do {
            guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  (request["version"] as? Int) == 1,
                  let method = request["method"] as? String else {
                throw BrowserControlFailure.invalid("browser RPC requires version 1 and a method")
            }
            await acquireRPC()
            defer { releaseRPC() }
            reconcileManagedTabs()
            let params = request["params"] as? [String: Any] ?? [:]
            let result = try await dispatch(method: method, params: params)
            let response: [String: Any] = [
                "ok": true,
                "id": request["id"] as? String ?? "",
                "result": result
            ]
            return .json(response)
        } catch {
            return .json([
                "ok": false,
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
        }
    }

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "tabs.list":
            return ["tabs": allTabs().map(tabDescription)]
        case "tabs.open":
            return try await openTab(params)
        case "tabs.show":
            let tab = try resolveTab(params)
            show(tab)
            return tabDescription(tab)
        case "tabs.close":
            let tab = try resolveTab(params)
            close(tab)
            return ["closed": tab.id.uuidString.lowercased()]
        case "tabs.navigate":
            let tab = try resolveTab(params)
            guard let rawURL = params["url"] as? String,
                  let url = normalizedURL(rawURL) else {
                throw BrowserControlFailure.invalid("navigate requires a valid url")
            }
            let managed = ensureManaged(tab)
            tab.url = url
            tab.address = url.absoluteString
            managed.webView.load(URLRequest(url: url))
            await waitForLoad(managed.webView)
            sync(tab, from: managed.webView)
            return tabDescription(tab)
        case "tabs.back", "tabs.forward", "tabs.reload":
            let tab = try resolveTab(params)
            let webView = ensureManaged(tab).webView
            if method == "tabs.back" { webView.goBack() }
            else if method == "tabs.forward" { webView.goForward() }
            else { webView.reload() }
            await waitForLoad(webView)
            sync(tab, from: webView)
            return tabDescription(tab)
        case "page.snapshot":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            await waitForLoad(managed.webView)
            return try await semanticSnapshot(managed)
        case "page.screenshot":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            await waitForLoad(managed.webView)
            return try await screenshot(managed, fullPage: params["full_page"] as? Bool ?? false)
        case "page.click":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            try await click(managed, params: params)
            try await Task.sleep(nanoseconds: 180_000_000)
            return try await screenshot(managed, fullPage: false)
        case "page.type":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            try await typeText(managed, params: params)
            try await Task.sleep(nanoseconds: 180_000_000)
            return try await screenshot(managed, fullPage: false)
        case "page.scroll":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            try await nativeScroll(managed,
                                   dx: params.double("dx") ?? 0,
                                   dy: params.double("dy") ?? 0)
            try await Task.sleep(nanoseconds: 180_000_000)
            return try await screenshot(managed, fullPage: false)
        default:
            throw BrowserControlFailure.invalid("unknown browser method \(method)")
        }
    }

    // MARK: tabs

    private func allTabs() -> [DashboardTab] {
        let visible = dashboards?.tabs ?? []
        let visibleIDs = Set(visible.map(\.id))
        let hidden = hiddenTabs.values.map(\.tab)
            .filter { !visibleIDs.contains($0.id) }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
        return visible + hidden
    }

    private func resolveTab(_ params: [String: Any]) throws -> DashboardTab {
        guard let token = params["tab_id"] as? String, !token.isEmpty else {
            throw BrowserControlFailure.invalid("tab_id is required")
        }
        let tokenLower = token.lowercased()
        let matches = allTabs().filter { $0.id.uuidString.lowercased().hasPrefix(tokenLower) }
        guard matches.count == 1, let tab = matches.first else {
            if matches.isEmpty { throw BrowserControlFailure.notFound("no browser tab matches \(token)") }
            throw BrowserControlFailure.invalid("tab id \(token) is ambiguous")
        }
        return tab
    }

    private func openTab(_ params: [String: Any]) async throws -> [String: Any] {
        guard let rawURL = params["url"] as? String,
              let url = normalizedURL(rawURL) else {
            throw BrowserControlFailure.invalid("open requires a valid url")
        }
        let width = CGFloat(min(max(params.int("width") ?? 1440, 320), 7680))
        let height = CGFloat(min(max(params.int("height") ?? 900, 320), 7680))
        let tab = DashboardTab(title: url.host ?? url.absoluteString,
                               host: "Argus · \(browserHostName)", url: url)
        tab.persist = true
        ownedTabIDs.insert(tab.id)
        let managed = makeOffscreenTab(tab, viewport: CGSize(width: width, height: height))
        managedTabs[tab.id] = managed
        hiddenTabs[tab.id] = managed
        managed.webView.load(URLRequest(url: url))
        await waitForLoad(managed.webView)
        sync(tab, from: managed.webView)
        if params["visible"] as? Bool == true { show(tab) }
        return tabDescription(tab)
    }

    private func show(_ tab: DashboardTab) {
        if let hidden = hiddenTabs.removeValue(forKey: tab.id) {
            hidden.detachFromOffscreenWindow()
        }
        dashboards?.adoptBrowserTab(tab, select: true)
        appState?.openWindowRequest = "dashboards"
    }

    private func close(_ tab: DashboardTab) {
        let managed = hiddenTabs.removeValue(forKey: tab.id) ?? managedTabs[tab.id]
        _ = dashboards?.close(tab.id)
        managedTabs.removeValue(forKey: tab.id)
        managed?.close()
        ownedTabIDs.remove(tab.id)
    }

    private func ensureManaged(_ tab: DashboardTab) -> BrowserManagedTab {
        if let existing = managedTabs[tab.id] { return existing }
        if let webView = tab.heldWebView ?? tab.webView {
            tab.persist = true
            tab.heldWebView = webView
            let managed = BrowserManagedTab(tab: tab, webView: webView, window: nil)
            managedTabs[tab.id] = managed
            return managed
        }
        let managed = makeOffscreenTab(tab, viewport: CGSize(width: 1440, height: 900))
        managedTabs[tab.id] = managed
        if let url = tab.url { managed.webView.load(URLRequest(url: url)) }
        return managed
    }

    private func makeOffscreenTab(_ tab: DashboardTab, viewport: CGSize) -> BrowserManagedTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: configuration)
        webView.setFrameSize(viewport)
        tab.heldWebView = webView
        tab.webView = webView
        let window = BrowserOffscreenWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: viewport),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.alphaValue = 0.01
        window.ignoresMouseEvents = false
        window.contentView = webView
        // WebKit paints while attached to an ordered window. Keeping the borderless
        // host far offscreen makes it genuinely hidden without using a special DOM
        // path that would differ from the visible browser.
        window.orderBack(nil)
        let managed = BrowserManagedTab(tab: tab, webView: webView, window: window)
        webView.navigationDelegate = managed
        return managed
    }

    private func reconcileManagedTabs() {
        let live = Set(allTabs().map(\.id))
        let staleIDs = managedTabs.keys.filter { !live.contains($0) }
        for id in staleIDs {
            managedTabs.removeValue(forKey: id)?.close()
            ownedTabIDs.remove(id)
        }
    }

    private func acquireRPC() async {
        if !rpcBusy {
            rpcBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            rpcWaiters.append(continuation)
        }
    }

    private func releaseRPC() {
        if rpcWaiters.isEmpty {
            rpcBusy = false
        } else {
            rpcWaiters.removeFirst().resume()
        }
    }

    private func tabDescription(_ tab: DashboardTab) -> [String: Any] {
        let webView = tab.heldWebView ?? tab.webView
        return [
            "id": tab.id.uuidString.lowercased(),
            "title": tab.displayTitle,
            "url": webView?.url?.absoluteString ?? tab.url?.absoluteString ?? "",
            "visible": dashboards?.tabs.contains(where: { $0.id == tab.id }) ?? false,
            "owner": ownedTabIDs.contains(tab.id) ? "agent" : "user",
            "loading": webView?.isLoading ?? false,
            "viewport": [
                "width": Int(webView?.bounds.width ?? 0),
                "height": Int(webView?.bounds.height ?? 0)
            ],
            "browser_host": browserHostName,
            "network_origin": browserHostName
        ]
    }

    private func normalizedURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        let hasSupportedScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("data:") || lower.hasPrefix("about:") || lower.hasPrefix("file://")
        if !hasSupportedScheme { value = "https://" + value }
        return URL(string: value)
    }

    private func sync(_ tab: DashboardTab, from webView: WKWebView) {
        if let url = webView.url {
            tab.url = url
            tab.address = url.absoluteString
        }
        if let title = webView.title, !title.isEmpty { tab.title = title }
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
        tab.isLoading = webView.isLoading
    }

    // MARK: observation

    private func semanticSnapshot(_ managed: BrowserManagedTab) async throws -> [String: Any] {
        let value = try await managed.webView.evaluate(script: BrowserScripts.semanticSnapshot)
        guard var snapshot = value as? [String: Any] else {
            throw BrowserControlFailure.failed("WebKit returned an invalid DOM snapshot")
        }
        managed.generation += 1
        snapshot["tab_id"] = managed.tab.id.uuidString.lowercased()
        snapshot["generation"] = managed.generation
        return snapshot
    }

    private func screenshot(_ managed: BrowserManagedTab, fullPage: Bool) async throws -> [String: Any] {
        let configuration = WKSnapshotConfiguration()
        // Keep the image coordinate space identical to CSS/WKWebView points even on
        // Retina displays. An agent can therefore click the exact x/y it sees in
        // the PNG without separately applying the display's backing scale factor.
        let backingScale = max(managed.webView.window?.backingScaleFactor
                               ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        configuration.snapshotWidth = NSNumber(value: managed.webView.bounds.width / backingScale)
        if fullPage,
           let size = try await managed.webView.evaluate(script: BrowserScripts.documentSize) as? [String: Any] {
            let width = min(max(size.double("width") ?? Double(managed.webView.bounds.width), 1), 16_384)
            let height = min(max(size.double("height") ?? Double(managed.webView.bounds.height), 1), 16_384)
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            configuration.snapshotWidth = NSNumber(value: width / backingScale)
        }
        let image = try await managed.webView.snapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw BrowserControlFailure.failed("could not encode the WebKit screenshot")
        }
        let scroll = (try? await managed.webView.evaluate(
            script: "({x: window.scrollX || 0, y: window.scrollY || 0})"
        )) as? [String: Any]
        managed.generation += 1
        var result: [String: Any] = [
            "tab_id": managed.tab.id.uuidString.lowercased(),
            "generation": managed.generation,
            "mime_type": "image/png",
            "width": representation.pixelsWide,
            "height": representation.pixelsHigh,
            "scroll_x": scroll?.double("x") ?? 0,
            "scroll_y": scroll?.double("y") ?? 0,
            "url": managed.webView.url?.absoluteString ?? "",
            "image_base64": png.base64EncodedString()
        ]
        if let mode = managed.lastInteractionMode { result["interaction_mode"] = mode }
        return result
    }

    // MARK: interaction

    private func click(_ managed: BrowserManagedTab, params: [String: Any]) async throws {
        if let ref = params["ref"] as? String {
            guard let rect = try await managed.webView.evaluate(script: BrowserScripts.rect(ref: ref)) as? [String: Any],
                  let x = rect.double("x"), let y = rect.double("y"),
                  let width = rect.double("width"), let height = rect.double("height") else {
                throw BrowserControlFailure.notFound("element reference \(ref) is missing or no longer current")
            }
            try await nativeClick(managed, x: x + width / 2, y: y + height / 2)
            return
        }
        guard let x = params.double("x"), let y = params.double("y") else {
            throw BrowserControlFailure.invalid("click requires coordinates or an element reference")
        }
        try await nativeClick(managed, x: x, y: y)
    }

    private func typeText(_ managed: BrowserManagedTab, params: [String: Any]) async throws {
        guard let text = params["text"] as? String else {
            throw BrowserControlFailure.invalid("type requires text")
        }
        if let ref = params["ref"] as? String {
            guard let rect = try await managed.webView.evaluate(script: BrowserScripts.rect(ref: ref)) as? [String: Any],
                  let x = rect.double("x"), let y = rect.double("y"),
                  let width = rect.double("width"), let height = rect.double("height") else {
                throw BrowserControlFailure.notFound("element reference \(ref) is missing or cannot be focused")
            }
            try await nativeType(managed, x: x + width / 2, y: y + height / 2, text: text)
            return
        } else if let x = params.double("x"), let y = params.double("y") {
            try await nativeType(managed, x: x, y: y, text: text)
            return
        }
        try await nativeType(managed, x: nil, y: nil, text: text)
    }

    private func nativeClick(_ managed: BrowserManagedTab, x: Double, y: Double) async throws {
        let webView = managed.webView
        guard x >= 0, y >= 0, x <= webView.bounds.width, y <= webView.bounds.height else {
            throw BrowserControlFailure.invalid("coordinates are outside the current viewport")
        }
        if !shouldUseNativeInput(managed) {
            guard (try await webView.evaluate(script: BrowserScripts.coordinateClick(x: x, y: y)) as? Bool) == true else {
                throw BrowserControlFailure.notFound("no page element exists at the requested coordinates")
            }
            managed.lastInteractionMode = "dom-coordinate-fallback"
            return
        }
        let before = try await trustedEventCount(webView, key: "pointer")
        let stage = try stageNativeInput(webView)
        defer { stage.restore() }
        try postNativeClick(webView, x: x, y: y)
        try await Task.sleep(nanoseconds: 80_000_000)
        let after = try await trustedEventCount(webView, key: "pointer")
        if after > before {
            managed.lastInteractionMode = "native"
        } else {
            guard (try await webView.evaluate(script: BrowserScripts.coordinateClick(x: x, y: y)) as? Bool) == true else {
                throw BrowserControlFailure.notFound("no page element exists at the requested coordinates")
            }
            managed.lastInteractionMode = "dom-coordinate-fallback"
        }
    }

    private func nativeType(_ managed: BrowserManagedTab, x: Double?, y: Double?, text: String) async throws {
        let webView = managed.webView
        if !shouldUseNativeInput(managed) {
            if let x, let y {
                guard (try await webView.evaluate(script: BrowserScripts.coordinateFocus(x: x, y: y)) as? Bool) == true else {
                    throw BrowserControlFailure.notFound("no editable page element exists at the requested coordinates")
                }
            }
            guard (try await webView.evaluate(script: BrowserScripts.prepareType(text: text)) as? Bool) == true,
                  (try await webView.evaluate(script: BrowserScripts.applyPreparedType)) as? Bool == true else {
                throw BrowserControlFailure.failed("the page has no focused editable element")
            }
            managed.lastInteractionMode = "dom-coordinate-fallback"
            return
        }
        let beforePointer = try await trustedEventCount(webView, key: "pointer")
        let stage = try stageNativeInput(webView)
        defer { stage.restore() }
        if let x, let y {
            try postNativeClick(webView, x: x, y: y)
            try await Task.sleep(nanoseconds: 60_000_000)
            let afterPointer = try await trustedEventCount(webView, key: "pointer")
            if afterPointer == beforePointer {
                guard (try await webView.evaluate(script: BrowserScripts.coordinateFocus(x: x, y: y)) as? Bool) == true else {
                    throw BrowserControlFailure.notFound("no editable page element exists at the requested coordinates")
                }
            }
        }
        guard (try await webView.evaluate(script: BrowserScripts.prepareType(text: text)) as? Bool) == true else {
            throw BrowserControlFailure.failed("the page has no focused editable element")
        }
        let beforeKeyboard = try await trustedEventCount(webView, key: "keyboard")
        guard let window = webView.window else {
            throw BrowserControlFailure.failed("the WebKit tab is not attached to a renderable window")
        }
        var timestamp = ProcessInfo.processInfo.systemUptime
        for character in text {
            let characters = String(character)
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: timestamp, windowNumber: window.windowNumber,
                                              context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters,
                                              isARepeat: false, keyCode: 0),
                  let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                                            timestamp: timestamp + 0.001, windowNumber: window.windowNumber,
                                            context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: 0) else {
                throw BrowserControlFailure.failed("could not construct native keyboard events")
            }
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
            timestamp += 0.002
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        let afterKeyboard = try await trustedEventCount(webView, key: "keyboard")
        let valueIsExact = (try await webView.evaluate(script: BrowserScripts.verifyPreparedType)) as? Bool == true
        if afterKeyboard > beforeKeyboard && valueIsExact {
            managed.lastInteractionMode = "native"
        } else {
            guard (try await webView.evaluate(script: BrowserScripts.applyPreparedType)) as? Bool == true else {
                throw BrowserControlFailure.failed("the page has no focused editable element")
            }
            managed.lastInteractionMode = "dom-coordinate-fallback"
        }
    }

    private func postNativeClick(_ webView: WKWebView, x: Double, y: Double) throws {
        // CSS/screenshot coordinates are top-left based. WKWebView is normally a
        // flipped NSView, but keep the conversion correct if WebKit changes that.
        let local = CGPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        let windowPoint = webView.convert(local, to: nil)
        guard let window = webView.window else {
            throw BrowserControlFailure.failed("the WebKit tab is not attached to a renderable window")
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                                            modifierFlags: [], timestamp: timestamp,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                                          modifierFlags: [], timestamp: timestamp + 0.01,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 0) else {
            throw BrowserControlFailure.failed("could not construct native mouse events")
        }
        // Queue through NSApplication instead of invoking WKWebView.mouseDown directly:
        // WebKit's remote content view is reached by the normal window dispatch path.
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    private func nativeScroll(_ managed: BrowserManagedTab, dx: Double, dy: Double) async throws {
        let webView = managed.webView
        if !shouldUseNativeInput(managed) {
            _ = try await webView.evaluate(script: BrowserScripts.scroll(dx: dx, dy: dy))
            managed.lastInteractionMode = "dom-coordinate-fallback"
            return
        }
        let before = try await trustedEventCount(webView, key: "wheel")
        let stage = try stageNativeInput(webView)
        defer { stage.restore() }
        let local = CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        let windowPoint = webView.convert(local, to: nil)
        guard let window = webView.window else {
            throw BrowserControlFailure.failed("the WebKit tab is not attached to a renderable window")
        }
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 2, wheel1: Int32(-dy),
                                    wheel2: Int32(-dx), wheel3: 0) else {
            throw BrowserControlFailure.failed("could not construct a native scroll event")
        }
        cgEvent.location = window.convertPoint(toScreen: windowPoint)
        cgEvent.postToPid(pid_t(ProcessInfo.processInfo.processIdentifier))
        try await Task.sleep(nanoseconds: 80_000_000)
        let after = try await trustedEventCount(webView, key: "wheel")
        if after == before {
            _ = try await webView.evaluate(script: BrowserScripts.scroll(dx: dx, dy: dy))
            managed.lastInteractionMode = "dom-coordinate-fallback"
        } else {
            managed.lastInteractionMode = "native"
        }
    }

    private func stageNativeInput(_ webView: WKWebView) throws -> BrowserNativeInputStage {
        guard let window = webView.window else {
            throw BrowserControlFailure.failed("the WebKit tab is not attached to a renderable window")
        }
        let stage = BrowserNativeInputStage(window: window)
        if window is BrowserOffscreenWindow {
            let origin = NSScreen.main?.visibleFrame.origin ?? .zero
            window.setFrameOrigin(origin)
            window.alphaValue = 0.002
            window.orderFront(nil)
        }
        window.makeKey()
        return stage
    }

    private func shouldUseNativeInput(_ managed: BrowserManagedTab) -> Bool {
        guard nativeInputEnabled else { return false }
        // A hidden WebKit window must briefly become key for trusted AppKit events.
        // Never steal focus while the user is actively working inside Argus; the
        // WebKit coordinate/ref path is deterministic and non-invasive. When Argus
        // is in the background, or the tab is already visible, native dispatch is safe.
        return !(managed.window is BrowserOffscreenWindow) || !NSApp.isActive
    }

    private func trustedEventCount(_ webView: WKWebView, key: String) async throws -> Int {
        let value = try await webView.evaluate(script: BrowserScripts.trustedEventCount(key: key))
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private func waitForLoad(_ webView: WKWebView, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !webView.isLoading,
               let state = try? await webView.evaluate(script: "document.readyState"),
               let ready = state as? String,
               ready == "interactive" || ready == "complete" {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

// MARK: - Managed WebKit state

@MainActor
private final class BrowserManagedTab: NSObject, WKNavigationDelegate {
    let tab: DashboardTab
    let webView: WKWebView
    var window: NSWindow?
    var generation = 0
    var lastInteractionMode: String?

    init(tab: DashboardTab, webView: WKWebView, window: NSWindow?) {
        self.tab = tab
        self.webView = webView
        self.window = window
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab.isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab.isLoading = false
        if let url = webView.url { tab.url = url; tab.address = url.absoluteString }
        if let title = webView.title, !title.isEmpty { tab.title = title }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab.isLoading = false
        tab.status = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab.isLoading = false
        tab.status = error.localizedDescription
    }

    func detachFromOffscreenWindow() {
        webView.removeFromSuperview()
        window?.contentView = nil
        window?.close()
        window = nil
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        window?.contentView = nil
        window?.close()
        window = nil
        tab.heldWebView = nil
        tab.webView = nil
    }
}

/// A borderless offscreen host normally cannot become key, so WebKit discards
/// native responder events. This window becomes key only for the duration of an
/// explicit agent input and the service immediately restores the user's window.
private final class BrowserOffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class BrowserNativeInputStage {
    private weak var window: NSWindow?
    private weak var previousKeyWindow: NSWindow?
    private let originalFrame: CGRect
    private let originalAlpha: CGFloat
    private let wasVisible: Bool

    init(window: NSWindow) {
        self.window = window
        previousKeyWindow = NSApp.keyWindow
        originalFrame = window.frame
        originalAlpha = window.alphaValue
        wasVisible = window.isVisible
    }

    func restore() {
        guard let window else { return }
        if window is BrowserOffscreenWindow {
            window.setFrame(originalFrame, display: false)
            window.alphaValue = originalAlpha
            if wasVisible { window.orderBack(nil) } else { window.orderOut(nil) }
        }
        (previousKeyWindow ?? NSApp.mainWindow)?.makeKey()
    }
}

private enum BrowserControlFailure: LocalizedError {
    case invalid(String)
    case notFound(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .notFound(let message), .failed(let message): return message
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        return nil
    }
}

private extension WKWebView {
    func evaluate(script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    func snapshot(configuration: WKSnapshotConfiguration) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            takeSnapshot(with: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: BrowserControlFailure.failed("WebKit produced no screenshot")) }
            }
        }
    }
}

// MARK: - Browser scripts

private enum BrowserScripts {
    static let semanticSnapshot = #"""
    (() => {
      window.__argusBrowserRef = window.__argusBrowserRef || 0;
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        const s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
      };
      const selector = 'a,button,input,textarea,select,[role],[contenteditable="true"],[tabindex]';
      const elements = [];
      for (const el of document.querySelectorAll(selector)) {
        if (!visible(el) || elements.length >= 750) continue;
        let ref = el.getAttribute('data-argus-browser-ref');
        if (!ref) {
          ref = 'e' + (++window.__argusBrowserRef);
          el.setAttribute('data-argus-browser-ref', ref);
        }
        const r = el.getBoundingClientRect();
        const type = (el.getAttribute('type') || '').toLowerCase();
        const rawValue = ('value' in el && type !== 'password') ? String(el.value || '') : '';
        const name = el.getAttribute('aria-label') || el.getAttribute('title') ||
          el.getAttribute('placeholder') || el.innerText || el.textContent || '';
        elements.push({
          ref, tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '',
          type, name: String(name).trim().replace(/\s+/g, ' ').slice(0, 300),
          value: rawValue.slice(0, 1000), disabled: !!el.disabled,
          rect: {x:r.x, y:r.y, width:r.width, height:r.height}
        });
      }
      return {
        url: location.href, title: document.title,
        viewport: {width: innerWidth, height: innerHeight, device_scale: devicePixelRatio},
        scroll: {x: scrollX, y: scrollY},
        text: String(document.body?.innerText || '').slice(0, 100000),
        elements
      };
    })()
    """#

    static let documentSize = #"""
    (() => ({
      width: Math.max(document.documentElement.scrollWidth, document.body?.scrollWidth || 0, innerWidth),
      height: Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0, innerHeight)
    }))()
    """#

    static func coordinateClick(x: Double, y: Double) -> String {
        return #"""
        (() => {
          const x = \#(x), y = \#(y);
          const el = document.elementFromPoint(x, y);
          if (!el) return false;
          const pointer = (name, buttons) => el.dispatchEvent(new PointerEvent(name, {
            bubbles:true, cancelable:true, clientX:x, clientY:y, pointerId:1,
            pointerType:'mouse', isPrimary:true, button:0, buttons
          }));
          const mouse = (name, buttons) => el.dispatchEvent(new MouseEvent(name, {
            bubbles:true, cancelable:true, clientX:x, clientY:y, button:0, buttons, view:window
          }));
          pointer('pointerover', 0); mouse('mouseover', 0);
          pointer('pointerdown', 1); mouse('mousedown', 1);
          el.focus({preventScroll:true});
          pointer('pointerup', 0); mouse('mouseup', 0); mouse('click', 0);
          return true;
        })()
        """#
    }

    static func coordinateFocus(x: Double, y: Double) -> String {
        #"""
        (() => {
          const el = document.elementFromPoint(\#(x), \#(y));
          if (!el) return false;
          el.focus({preventScroll:true});
          return document.activeElement === el || el.contains(document.activeElement);
        })()
        """#
    }

    static func prepareType(text: String) -> String {
        let encoded = jsString(text)
        return #"""
        (() => {
          const el = document.activeElement;
          const text = \#(encoded);
          if (!el) return false;
          if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
            const start = el.selectionStart ?? el.value.length;
            const end = el.selectionEnd ?? start;
            window.__argusPreparedType = {
              el, kind:'value', start, end, original:String(el.value),
              expected:String(el.value).slice(0, start) + text + String(el.value).slice(end)
            };
            return true;
          }
          if (el.isContentEditable) {
            window.__argusPreparedType = {
              el, kind:'contenteditable', originalHTML:el.innerHTML, text
            };
            return true;
          }
          return false;
        })()
        """#
    }

    static let verifyPreparedType = #"""
    (() => {
      const state = window.__argusPreparedType;
      if (!state?.el) return false;
      if (state.kind === 'value') return String(state.el.value) === state.expected;
      return String(state.el.textContent || '').includes(state.text);
    })()
    """#

    static let applyPreparedType = #"""
    (() => {
      const state = window.__argusPreparedType;
      const el = state?.el;
      if (!el || !el.isConnected) return false;
      if (state.kind === 'value') {
        const proto = el instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) setter.call(el, state.expected); else el.value = state.expected;
        const caret = state.start + (state.expected.length - state.original.length + state.end - state.start);
        try { el.setSelectionRange(caret, caret); } catch (_) {}
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        return String(el.value) === state.expected;
      }
      if (state.kind === 'contenteditable') {
        el.innerHTML = state.originalHTML;
        el.focus({preventScroll:true});
        const selection = getSelection();
        const range = document.createRange();
        range.selectNodeContents(el); range.collapse(false);
        selection.removeAllRanges(); selection.addRange(range);
        const inserted = document.execCommand('insertText', false, state.text);
        el.dispatchEvent(new Event('input', {bubbles:true}));
        return inserted || String(el.textContent || '').includes(state.text);
      }
      return false;
    })()
    """#

    static func scroll(dx: Double, dy: Double) -> String {
        "window.scrollBy({left:\(dx), top:\(dy), behavior:'instant'}); true"
    }

    static func trustedEventCount(key: String) -> String {
        let encoded = jsString(key)
        return #"""
        (() => {
          if (!window.__argusTrustedEvents) {
            window.__argusTrustedEvents = {pointer:0, keyboard:0, wheel:0};
            for (const name of ['pointerdown','mousedown','click'])
              addEventListener(name, e => { if (e.isTrusted) window.__argusTrustedEvents.pointer++; }, true);
            for (const name of ['keydown','beforeinput','input'])
              addEventListener(name, e => { if (e.isTrusted) window.__argusTrustedEvents.keyboard++; }, true);
            addEventListener('wheel', e => { if (e.isTrusted) window.__argusTrustedEvents.wheel++; }, true);
          }
          return window.__argusTrustedEvents[\#(encoded)] || 0;
        })()
        """#
    }

    static func rect(ref: String) -> String {
        let encoded = jsString(ref)
        return #"""
        (() => {
          const el = [...document.querySelectorAll('[data-argus-browser-ref]')]
            .find(node => node.getAttribute('data-argus-browser-ref') === \#(encoded));
          if (!el) return null;
          el.scrollIntoView({block:'center', inline:'center'});
          const r = el.getBoundingClientRect();
          return {x:r.x, y:r.y, width:r.width, height:r.height};
        })()
        """#
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

// MARK: - Tiny loopback HTTP server

private struct BrowserHTTPResponse {
    let status: Int
    let body: Data

    static func json(_ value: Any, status: Int = 200) -> BrowserHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data(#"{"ok":false,"error":"serialization failed"}"#.utf8)
        return BrowserHTTPResponse(status: status, body: body)
    }

    static let serviceUnavailable = json(["ok": false, "error": "Argus browser provider stopped"], status: 503)
}

private final class BrowserLoopbackServer {
    typealias Handler = @MainActor (Data) async -> BrowserHTTPResponse
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.argus.browser-provider")
    private var listener: NWListener?

    init(handler: @escaping Handler) { self.handler = handler }

    func start(ready: @escaping (UInt16) -> Void) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    ready(port.rawValue)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            NSLog("Argus browser provider failed to listen: %@", error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > 20 * 1024 * 1024 {
                self.send(.json(["ok": false, "error": "request too large"], status: 413), on: connection)
                return
            }
            if let request = BrowserHTTPRequest.parse(accumulated) {
                guard request.method == "POST", request.path == "/rpc" else {
                    self.send(.json(["ok": false, "error": "not found"], status: 404), on: connection)
                    return
                }
                Task { @MainActor in
                    let response = await self.handler(request.body)
                    self.send(response, on: connection)
                }
            } else if complete || error != nil {
                self.send(.json(["ok": false, "error": "incomplete HTTP request"], status: 400), on: connection)
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private func send(_ response: BrowserHTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Service Unavailable"
        }
        var data = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private struct BrowserHTTPRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) -> BrowserHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headers = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headers.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return BrowserHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                                  body: data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }
}
