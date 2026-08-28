import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import WebKit

// MARK: - Agent browser provider

/// The optional browser.v1 provider hosted by Argus. The Go broker only discovers
/// and relays this loopback service; all browser state and WebKit work remains here.
@MainActor
final class BrowserControlService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var providerPort: UInt16?

    private weak var dashboards: DashboardsModel?
    private weak var credentialVault: CredentialVaultStore?
    private var listener: BrowserLoopbackServer?
    private var heartbeat: Timer?
    private var lifecycleWatchdog: Timer?
    private var hiddenTabs: [UUID: BrowserManagedTab] = [:]
    private var managedTabs: [UUID: BrowserManagedTab] = [:]
    private var ownedTabIDs: Set<UUID> = []
    private var automaticClosures: [UUID: BrowserAutomaticTabClosure] = [:]
    private var rpcBusy = false
    private var rpcWaiters: [CheckedContinuation<Void, Never>] = []
    private let browserHostName: String
    private let hiddenTabLifetime: TimeInterval
    private let hiddenTabMemoryLimit: UInt64
    private let now: () -> Date
    private let webProcessUsage: (WKWebView) -> BrowserWebProcessUsage?
    private let appWindowCapture: () throws -> CGImage

    init(hiddenTabLifetime: TimeInterval = 12 * 60 * 60,
         hiddenTabMemoryLimit: UInt64 = 4 * 1_024 * 1_024 * 1_024,
         now: @escaping () -> Date = Date.init,
         webProcessUsage: @escaping (WKWebView) -> BrowserWebProcessUsage? = BrowserWebProcessMonitor.usage,
         appWindowCapture: @escaping () throws -> CGImage = ArgusWindowCapture.captureMainWindow) {
        browserHostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.hiddenTabLifetime = hiddenTabLifetime
        self.hiddenTabMemoryLimit = hiddenTabMemoryLimit
        self.now = now
        self.webProcessUsage = webProcessUsage
        self.appWindowCapture = appWindowCapture
    }

    func start(dashboards: DashboardsModel, credentialVault: CredentialVaultStore) {
        self.dashboards = dashboards
        self.credentialVault = credentialVault
        guard listener == nil else { return }
        let server = BrowserLoopbackServer { [weak self] body in
            guard let self else { return BrowserHTTPResponse.serviceUnavailable }
            return await self.handleRPC(body)
        }
        listener = server
        startLifecycleWatchdog()
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
    func bindForTesting(dashboards: DashboardsModel,
                        credentialVault: CredentialVaultStore? = nil) {
        self.dashboards = dashboards
        self.credentialVault = credentialVault
    }

    func processRPCForTesting(_ body: Data) async -> Data {
        await handleRPC(body).body
    }

    func runLifecycleWatchdogForTesting() {
        enforceHiddenTabLimits()
    }

    func repositionHiddenHostForTesting(tabID: String, to origin: CGPoint)
        -> (alpha: CGFloat, frame: CGRect, isVisible: Bool)? {
        guard let id = UUID(uuidString: tabID), let window = hiddenTabs[id]?.window else { return nil }
        window.setFrameOrigin(origin)
        return (window.alphaValue, window.frame, window.isVisible)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.registerProvider() }
        }
    }

    private func startLifecycleWatchdog() {
        lifecycleWatchdog?.invalidate()
        lifecycleWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceHiddenTabLimits() }
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
        var requestedTabToken: String?
        do {
            guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  (request["version"] as? Int) == 1,
                  let method = request["method"] as? String else {
                throw BrowserControlFailure.invalid("browser RPC requires version 1 and a method")
            }
            reconcileManagedTabs()
            let params = request["params"] as? [String: Any] ?? [:]
            requestedTabToken = params["tab_id"] as? String
            let caller = browserCredentialCaller(request["caller"])
            let result: Any
            // An approval may remain pending for minutes. It must not hold the
            // browser interaction lane and make unrelated tabs appear frozen.
            if method == "credentials.list" || method == "credentials.request" ||
                method == "api_keys.request" {
                result = try await dispatch(method: method, params: params, caller: caller)
            } else {
                await acquireRPC()
                defer { releaseRPC() }
                result = try await dispatch(method: method, params: params, caller: caller)
            }
            if let closure = automaticClosure(matching: params["tab_id"] as? String) {
                throw BrowserControlFailure.failed(closure.message)
            }
            let response: [String: Any] = [
                "ok": true,
                "id": request["id"] as? String ?? "",
                "result": result
            ]
            return .json(response)
        } catch {
            let reportedError: Error
            if let closure = automaticClosure(matching: requestedTabToken) {
                reportedError = BrowserControlFailure.failed(closure.message)
            } else {
                reportedError = error
            }
            return .json([
                "ok": false,
                "error": (reportedError as? LocalizedError)?.errorDescription ?? reportedError.localizedDescription
            ])
        }
    }

    private func dispatch(method: String, params: [String: Any],
                          caller: BrowserCredentialCaller?) async throws -> Any {
        switch method {
        case "app.screenshot":
            let image = try appWindowCapture()
            let encoded = try await BrowserScreenshotEncoder.encode(image)
            return [
                "scope": "argus-window",
                "mime_type": "image/png",
                "width": encoded.width,
                "height": encoded.height,
                "image_base64": encoded.base64
            ]
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
        case "page.upload":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            let uploaded = try await uploadFiles(managed, params: params)
            try await Task.sleep(nanoseconds: 180_000_000)
            var observation = try await screenshot(managed, fullPage: false)
            observation["uploaded"] = uploaded
            return observation
        case "page.scroll":
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            try await isolatedScroll(managed,
                                     dx: params.double("dx") ?? 0,
                                     dy: params.double("dy") ?? 0)
            try await Task.sleep(nanoseconds: 180_000_000)
            return try await screenshot(managed, fullPage: false)
        case "credentials.list":
            guard let credentialVault else {
                throw BrowserControlFailure.failed("Argus Credential Vault is unavailable")
            }
            return ["credentials": credentialVault.entries.filter { $0.kind == .login }.map { entry in
                ["name": entry.name, "group": entry.group,
                 "fields": ["username", "password"]] as [String: Any]
            }]
        case "credentials.request":
            guard let credentialVault else {
                throw BrowserControlFailure.failed("Argus Credential Vault is unavailable")
            }
            guard let caller else {
                throw BrowserControlFailure.invalid("credential access must originate from a verified ut panel")
            }
            guard let name = params["credential"] as? String, !name.isEmpty else {
                throw BrowserControlFailure.invalid("credential is required")
            }
            var domain = ""
            if params["tab_id"] as? String != nil {
                let tab = try resolveTab(params)
                domain = (tab.heldWebView ?? tab.webView)?.url?.host ?? tab.url?.host ?? ""
            }
            let grant = try await credentialVault.requestGrant(
                credentialName: name, caller: caller, domain: domain
            )
            return ["grant": grant.token, "duration": grant.duration.rawValue,
                    "scope": grant.scope.rawValue]
        case "credentials.fill":
            guard let credentialVault else {
                throw BrowserControlFailure.failed("Argus Credential Vault is unavailable")
            }
            guard let caller else {
                throw BrowserControlFailure.invalid("credential access must originate from a verified ut panel")
            }
            guard let name = params["credential"] as? String, !name.isEmpty,
                  let token = params["grant"] as? String, !token.isEmpty,
                  let targets = params["targets"] as? [String: Any], !targets.isEmpty else {
                throw BrowserControlFailure.invalid("grant, credential, and at least one field target are required")
            }
            let tab = try resolveTab(params)
            let managed = ensureManaged(tab)
            let domain = managed.webView.url?.host ?? tab.url?.host ?? ""
            let (entry, secret) = try credentialVault.resolve(
                grant: token, credentialName: name, caller: caller, domain: domain
            )
            let filled = try await fillCredentialFields(managed, secret: secret, targets: targets)
            credentialVault.markGrantUsed(token, entry: entry, caller: caller)
            return ["tab_id": tab.id.uuidString.lowercased(),
                    "url": managed.webView.url?.absoluteString ?? "",
                    "filled": filled]
        case "api_keys.request":
            guard let credentialVault else {
                throw BrowserControlFailure.failed("Argus Credential Vault is unavailable")
            }
            guard let caller else {
                throw BrowserControlFailure.invalid("API-key access must originate from a verified ut panel")
            }
            guard let name = params["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowserControlFailure.invalid("saved API-key name is required")
            }
            guard !caller.workingDirectory.isEmpty, !caller.dotenvPath.isEmpty,
                  caller.dotenvPath == Self.dotenvPath(for: caller.workingDirectory) else {
                throw BrowserControlFailure.invalid("the calling panel did not provide a valid .env destination")
            }
            let existingVariables = Set(params["existing_variables"] as? [String] ?? [])
            if let entry = credentialVault.apiKeyEntries(named: name).first,
               existingVariables.contains(entry.environmentVariable) {
                return ["variable": entry.environmentVariable, "value": "",
                        "credential": entry.name, "already_present": true]
            }
            let approval = try await credentialVault.requestAPIKey(
                name: name, destination: caller.dotenvPath, caller: caller
            )
            return ["variable": approval.variable, "value": approval.value,
                    "credential": approval.entry.name, "already_present": false]
        default:
            throw BrowserControlFailure.invalid("unknown browser method \(method)")
        }
    }

    private func browserCredentialCaller(_ value: Any?) -> BrowserCredentialCaller? {
        guard let raw = value as? [String: Any] else { return nil }
        let caller = BrowserCredentialCaller(
            machineName: raw["machine_name"] as? String ?? "",
            machineHost: raw["machine_host"] as? String ?? "",
            sessionName: raw["session_name"] as? String ?? "",
            stableSessionID: raw["stable_session_id"] as? String ?? "",
            sessionLineageID: raw["session_lineage_id"] as? String ?? "",
            workingDirectory: raw["working_directory"] as? String ?? "",
            dotenvPath: raw["dotenv_path"] as? String ?? ""
        )
        return caller.isAttributed ? caller : nil
    }

    private static func dotenvPath(for workingDirectory: String) -> String {
        guard let last = workingDirectory.last else { return "" }
        if last == "/" || last == "\\" { return workingDirectory + ".env" }
        let separator = workingDirectory.contains("\\") && !workingDirectory.contains("/") ? "\\" : "/"
        return workingDirectory + separator + ".env"
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
            if matches.isEmpty, let closure = automaticClosure(matching: token) {
                throw BrowserControlFailure.failed(closure.message)
            }
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
        let managed = makeOffscreenTab(tab, viewport: CGSize(width: width, height: height),
                                       createdAt: now())
        managedTabs[tab.id] = managed
        hiddenTabs[tab.id] = managed
        managed.webView.load(URLRequest(url: url))
        await waitForLoad(managed.webView)
        if let closure = automaticClosures[tab.id] {
            throw BrowserControlFailure.failed(closure.message)
        }
        sync(tab, from: managed.webView)
        if params["visible"] as? Bool == true { show(tab) }
        return tabDescription(tab)
    }

    private func show(_ tab: DashboardTab) {
        // "Visible" means retained in the user's Dashboard tab strip. It must
        // never open an Argus window or replace the tab the user is reading.
        // Keep the offscreen host until WebTabView naturally reparents the live
        // WKWebView when the user selects this tab.
        _ = hiddenTabs.removeValue(forKey: tab.id)
        let shouldSelect = dashboards?.activeID == nil
        dashboards?.adoptBrowserTab(tab, select: shouldSelect)
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
            let managed = BrowserManagedTab(tab: tab, webView: webView, window: nil,
                                            createdAt: now())
            managedTabs[tab.id] = managed
            return managed
        }
        let managed = makeOffscreenTab(tab, viewport: CGSize(width: 1440, height: 900),
                                       createdAt: now())
        managedTabs[tab.id] = managed
        if let url = tab.url { managed.webView.load(URLRequest(url: url)) }
        return managed
    }

    private func makeOffscreenTab(_ tab: DashboardTab, viewport: CGSize,
                                  createdAt: Date) -> BrowserManagedTab {
        let configuration = ArgusBrowserIdentity.persistentConfiguration()
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
        // WebKit stays attached to an ordered render surface, but the surface is
        // completely absent from the compositor. macOS may relocate an offscreen
        // window during Space/full-screen changes; zero alpha keeps that harmless.
        window.alphaValue = 0
        // Hidden browser rendering must never intercept the user's pointer.
        window.ignoresMouseEvents = true
        window.contentView = webView
        // WebKit paints while attached to an ordered window. Keeping the borderless
        // host offscreen avoids unnecessary composition work; zero alpha above is
        // the actual visibility guarantee and does not depend on these coordinates.
        window.orderBack(nil)
        let managed = BrowserManagedTab(tab: tab, webView: webView, window: window,
                                        createdAt: createdAt)
        webView.navigationDelegate = managed
        webView.uiDelegate = managed
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

    private func enforceHiddenTabLimits() {
        let checkedAt = now()
        automaticClosures = automaticClosures.filter {
            checkedAt.timeIntervalSince($0.value.closedAt) < 24 * 60 * 60
        }

        let expired = hiddenTabs.values.filter {
            checkedAt.timeIntervalSince($0.createdAt) >= hiddenTabLifetime
        }
        for managed in expired {
            closeAutomatically(
                managed,
                message: "Hidden browser tab \(managed.tab.id.uuidString.lowercased()) expired after its 12-hour lifetime limit. Open a new tab and retry.",
                at: checkedAt
            )
        }

        var processGroups: [Int32: (bytes: UInt64, tabs: [BrowserManagedTab])] = [:]
        for managed in hiddenTabs.values {
            guard let usage = webProcessUsage(managed.webView), usage.processID > 0 else { continue }
            var group = processGroups[usage.processID] ?? (usage.residentBytes, [])
            group.bytes = max(group.bytes, usage.residentBytes)
            group.tabs.append(managed)
            processGroups[usage.processID] = group
        }
        for group in processGroups.values where group.bytes >= hiddenTabMemoryLimit {
            let actual = Self.gibibytes(group.bytes)
            let limit = Self.gibibytes(hiddenTabMemoryLimit)
            for managed in group.tabs {
                closeAutomatically(
                    managed,
                    message: "Hidden browser tab \(managed.tab.id.uuidString.lowercased()) was closed because its WebKit content process used \(actual), exceeding the \(limit) limit. Open a new tab and retry.",
                    at: checkedAt
                )
            }
        }
    }

    private func closeAutomatically(_ managed: BrowserManagedTab, message: String, at date: Date) {
        let id = managed.tab.id
        guard hiddenTabs.removeValue(forKey: id) != nil else { return }
        automaticClosures[id] = BrowserAutomaticTabClosure(message: message, closedAt: date)
        managed.tab.status = message
        managedTabs.removeValue(forKey: id)
        managed.close()
        ownedTabIDs.remove(id)
        NSLog("Argus browser watchdog: %@", message)
    }

    private func automaticClosure(matching token: String?) -> BrowserAutomaticTabClosure? {
        guard let token, !token.isEmpty else { return nil }
        let lowered = token.lowercased()
        let matches = automaticClosures.filter {
            $0.key.uuidString.lowercased().hasPrefix(lowered)
        }
        return matches.count == 1 ? matches.first?.value : nil
    }

    private static func gibibytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / Double(1_024 * 1_024 * 1_024))
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
        var description: [String: Any] = [
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
        if let managed = hiddenTabs[tab.id] {
            description["hidden_expires_at"] = ISO8601DateFormatter().string(
                from: managed.createdAt.addingTimeInterval(hiddenTabLifetime)
            )
            description["memory_limit_bytes"] = hiddenTabMemoryLimit
        }
        return description
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
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserControlFailure.failed("could not encode the WebKit screenshot")
        }
        // WKWebView itself is main-thread-bound, but PNG compression and base64 are
        // pure CPU/copy work. Keeping them off MainActor prevents a large or busy
        // page observation from freezing terminal scrolling and clicks in Argus.
        let encoded = try await BrowserScreenshotEncoder.encode(cgImage)
        let scroll = (try? await managed.webView.evaluate(
            script: "({x: window.scrollX || 0, y: window.scrollY || 0})"
        )) as? [String: Any]
        managed.generation += 1
        var result: [String: Any] = [
            "tab_id": managed.tab.id.uuidString.lowercased(),
            "generation": managed.generation,
            "mime_type": "image/png",
            "width": encoded.width,
            "height": encoded.height,
            "scroll_x": scroll?.double("x") ?? 0,
            "scroll_y": scroll?.double("y") ?? 0,
            "url": managed.webView.url?.absoluteString ?? "",
            "image_base64": encoded.base64
        ]
        if let mode = managed.lastInteractionMode { result["interaction_mode"] = mode }
        return result
    }

    // MARK: interaction

    private func fillCredentialFields(_ managed: BrowserManagedTab,
                                      secret: CredentialVaultSecret,
                                      targets: [String: Any]) async throws -> [String] {
        var filled: [String] = []
        for field in ["username", "password"] {
            guard let target = targets[field] as? [String: Any] else { continue }
            guard let value = secret.value(for: field) else {
                throw BrowserControlFailure.invalid("credential has no \(field) field")
            }
            var arguments: [String: Any] = [
                "targetRef": NSNull(), "targetX": NSNull(), "targetY": NSNull()
            ]
            let point: CGPoint
            if let ref = target["ref"] as? String, !ref.isEmpty {
                arguments["targetRef"] = ref
                guard let rect = try await managed.webView.evaluate(
                    script: BrowserScripts.rect(ref: ref)
                ) as? [String: Any],
                      let x = rect.double("x"), let y = rect.double("y"),
                      let width = rect.double("width"), let height = rect.double("height") else {
                    throw BrowserControlFailure.notFound("the \(field) target is no longer present")
                }
                point = CGPoint(x: x + width / 2, y: y + height / 2)
            } else if let x = target.double("x"), let y = target.double("y"), x >= 0, y >= 0 {
                arguments["targetX"] = x
                arguments["targetY"] = y
                point = CGPoint(x: x, y: y)
            } else {
                throw BrowserControlFailure.invalid("\(field) target requires an element ref or x/y coordinates")
            }

            // The secret never enters page JavaScript. Native WebKit input can
            // reach cross-origin frames, shadow DOM, and framework-controlled
            // fields that document.elementFromPoint cannot inspect. Marking is
            // best-effort and only prevents a reachable field from appearing in
            // a later semantic snapshot.
            _ = try? await managed.webView.callAsync(
                script: BrowserScripts.markProtectedField,
                arguments: arguments
            )
            try await isolatedProtectedType(managed, point: point, text: value)
            filled.append(field)
        }
        guard !filled.isEmpty else {
            throw BrowserControlFailure.invalid("no supported credential fields were targeted")
        }
        managed.lastInteractionMode = "protected-credential-fill"
        return filled
    }

    private func isolatedProtectedType(_ managed: BrowserManagedTab,
                                       point: CGPoint, text: String) async throws {
        try nativeClick(managed, x: point.x, y: point.y)
        try await Task.sleep(nanoseconds: 40_000_000)
        try nativeType(managed, text: text, replacingCurrentField: true)
    }

    private func click(_ managed: BrowserManagedTab, params: [String: Any]) async throws {
        if let ref = params["ref"] as? String {
            guard let rect = try await managed.webView.evaluate(script: BrowserScripts.rect(ref: ref)) as? [String: Any],
                  let x = rect.double("x"), let y = rect.double("y"),
                  let width = rect.double("width"), let height = rect.double("height") else {
                throw BrowserControlFailure.notFound("element reference \(ref) is missing or no longer current")
            }
            try await domClick(managed, x: x + width / 2, y: y + height / 2)
            return
        }
        guard let x = params.double("x"), let y = params.double("y") else {
            throw BrowserControlFailure.invalid("click requires coordinates or an element reference")
        }
        try nativeClick(managed, x: x, y: y)
    }

    private func typeText(_ managed: BrowserManagedTab, params: [String: Any]) async throws {
        guard let text = params["text"] as? String else {
            throw BrowserControlFailure.invalid("type requires text")
        }
        if try await typeIntoContentEditable(managed, params: params, text: text) {
            return
        }
        if let ref = params["ref"] as? String {
            guard (try await managed.webView.evaluate(
                script: BrowserScripts.focus(ref: ref)
            ) as? Bool) == true else {
                throw BrowserControlFailure.notFound("element reference \(ref) is missing or cannot be focused")
            }
            try await isolatedType(managed, x: nil, y: nil, text: text)
            return
        } else if let x = params.double("x"), let y = params.double("y") {
            try await isolatedType(managed, x: x, y: y, text: text)
            return
        }
        try await isolatedType(managed, x: nil, y: nil, text: text)
    }

    /// Contenteditable editors such as Gmail's reply body may synchronously
    /// replace themselves when focused. Resolve and edit them in one WebKit call,
    /// before focus can invalidate the DOM ref between two RPC steps. Standard
    /// inputs return `handled:false` and retain the existing value-setter path.
    private func typeIntoContentEditable(_ managed: BrowserManagedTab,
                                         params: [String: Any], text: String) async throws -> Bool {
        var arguments: [String: Any] = [
            "insertedText": text,
            "targetRef": NSNull(), "targetX": NSNull(), "targetY": NSNull()
        ]
        if let ref = params["ref"] as? String { arguments["targetRef"] = ref }
        if let x = params.double("x") { arguments["targetX"] = x }
        if let y = params.double("y") { arguments["targetY"] = y }
        guard let result = try await managed.webView.callAsync(
            script: BrowserScripts.typeIntoContentEditable,
            arguments: arguments
        ) as? [String: Any] else {
            throw BrowserControlFailure.failed("WebKit returned an invalid typing result")
        }
        guard result["handled"] as? Bool == true else { return false }
        guard result["ok"] as? Bool == true else {
            throw BrowserControlFailure.failed(
                result["error"] as? String ?? "the contenteditable element rejected text"
            )
        }
        managed.lastInteractionMode = "dom-contenteditable"
        return true
    }

    private func uploadFiles(_ managed: BrowserManagedTab,
                             params: [String: Any]) async throws -> [String] {
        guard let payloads = params["files"] as? [[String: Any]], !payloads.isEmpty else {
            throw BrowserControlFailure.invalid("upload requires at least one file")
        }
        var files: [[String: Any]] = []
        var totalBytes = 0
        for payload in payloads {
            guard let name = payload["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let base64 = payload["data_base64"] as? String,
                  let decoded = Data(base64Encoded: base64) else {
                throw BrowserControlFailure.invalid("upload contains an invalid file payload")
            }
            totalBytes += decoded.count
            guard totalBytes <= 32 * 1024 * 1024 else {
                throw BrowserControlFailure.invalid("upload exceeds the 32 MiB total limit")
            }
            files.append([
                "name": name,
                "mimeType": payload["mime_type"] as? String ?? "application/octet-stream",
                "dataBase64": base64,
                "lastModified": payload["last_modified_ms"] as? NSNumber ?? 0
            ])
        }
        var arguments: [String: Any] = [
            "uploadFiles": files,
            "targetRef": NSNull(), "targetX": NSNull(), "targetY": NSNull()
        ]
        if let ref = params["ref"] as? String { arguments["targetRef"] = ref }
        if let x = params.double("x") { arguments["targetX"] = x }
        if let y = params.double("y") { arguments["targetY"] = y }
        guard let result = try await managed.webView.callAsync(
            script: BrowserScripts.attachFiles,
            arguments: arguments
        ) as? [String: Any] else {
            throw BrowserControlFailure.failed("the page did not accept the uploaded files")
        }
        guard result["ok"] as? Bool == true else {
            throw BrowserControlFailure.notFound(
                result["error"] as? String ?? "no matching file input was found"
            )
        }
        managed.lastInteractionMode = "dom-file-upload"
        return result["names"] as? [String] ?? files.compactMap { $0["name"] as? String }
    }

    /// Element-reference clicks retain the in-page path because native HTML select
    /// menus are mirrored into the document so screenshots can observe them.
    private func domClick(_ managed: BrowserManagedTab, x: Double, y: Double) async throws {
        let webView = managed.webView
        guard x >= 0, y >= 0, x <= webView.bounds.width, y <= webView.bounds.height else {
            throw BrowserControlFailure.invalid("coordinates are outside the current viewport")
        }
        guard (try await webView.evaluate(script: BrowserScripts.coordinateClick(x: x, y: y)) as? Bool) == true else {
            throw BrowserControlFailure.notFound("no page element exists at the requested coordinates")
        }
        managed.lastInteractionMode = "dom-injected"
    }

    /// Coordinate clicks enter the addressed WKWebView's native AppKit input path.
    /// They are delivered directly to its content view rather than posted through
    /// NSApplication/CGEvent, so WebKit owns hit testing (including child frames)
    /// without moving the pointer or activating Argus/the offscreen host window.
    private func nativeClick(_ managed: BrowserManagedTab, x: Double, y: Double) throws {
        let webView = managed.webView
        guard x >= 0, y >= 0, x <= webView.bounds.width, y <= webView.bounds.height else {
            throw BrowserControlFailure.invalid("coordinates are outside the current viewport")
        }
        guard let window = webView.window ?? managed.window else {
            throw BrowserControlFailure.failed("the browser tab has no live WebKit host")
        }

        let point = CGPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        guard let target = webView.hitTest(point) else {
            throw BrowserControlFailure.notFound("no WebKit content exists at the requested coordinates")
        }
        let location = webView.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        func mouseEvent(_ type: NSEvent.EventType, clickCount: Int, pressure: Float) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: pressure
            ) else {
                throw BrowserControlFailure.failed("could not construct a WebKit mouse event")
            }
            return event
        }

        target.mouseMoved(with: try mouseEvent(.mouseMoved, clickCount: 0, pressure: 0))
        target.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 1, pressure: 1))
        target.mouseUp(with: try mouseEvent(.leftMouseUp, clickCount: 1, pressure: 0))
        managed.lastInteractionMode = "native-webkit"
    }

    private func isolatedType(_ managed: BrowserManagedTab, x: Double?, y: Double?, text: String) async throws {
        let webView = managed.webView
        if let x, let y {
            try nativeClick(managed, x: x, y: y)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        if x == nil, y == nil,
           (try await webView.evaluate(script: BrowserScripts.prepareType(text: text)) as? Bool) == true,
           (try await webView.evaluate(script: BrowserScripts.applyPreparedType)) as? Bool == true {
            managed.lastInteractionMode = "dom-injected"
            return
        }
        try nativeType(managed, text: text)
    }

    /// Inserts through WebKit's NSTextInputClient after a native coordinate click.
    /// A hidden tab's offscreen window has its own first responder even though it can
    /// never become key, so text stays scoped to that page and not the user's app.
    private func nativeType(_ managed: BrowserManagedTab, text: String,
                            replacingCurrentField: Bool = false) throws {
        guard let responder = (managed.webView.window ?? managed.window)?.firstResponder,
              let inputClient = responder as? NSTextInputClient else {
            throw BrowserControlFailure.failed("the page has no focused WebKit text input")
        }
        if replacingCurrentField {
            inputClient.doCommand(by: NSSelectorFromString("selectAll:"))
        }
        inputClient.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        managed.lastInteractionMode = "native-webkit"
    }

    private func isolatedScroll(_ managed: BrowserManagedTab, dx: Double, dy: Double) async throws {
        _ = try await managed.webView.evaluate(script: BrowserScripts.scroll(dx: dx, dy: dy))
        managed.lastInteractionMode = "dom-injected"
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
private final class BrowserManagedTab: ArgusRemoteWebUIDelegate, WKNavigationDelegate {
    let tab: DashboardTab
    let webView: WKWebView
    let createdAt: Date
    var window: NSWindow?
    var generation = 0
    var lastInteractionMode: String?

    init(tab: DashboardTab, webView: WKWebView, window: NSWindow?, createdAt: Date) {
        self.tab = tab
        self.webView = webView
        self.window = window
        self.createdAt = createdAt
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab.isLoading = true
        tab.status = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab.isLoading = false
        tab.status = nil
        if let url = webView.url { tab.url = url; tab.address = url.absoluteString }
        if let title = webView.title, !title.isEmpty { tab.title = title }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        switch DashboardNavigationFailurePolicy.disposition(for: error) {
        case .superseded:
            // Redirects and a newer agent navigation cancel the older request.
            // Preserve the newer load instead of leaving a permanent -999 error.
            tab.isLoading = webView.isLoading
        case .contentHandled:
            tab.isLoading = false
            tab.status = nil
        case .retryable, .report:
            tab.isLoading = false
            tab.status = error.localizedDescription
        }
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
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window?.contentView = nil
        window?.close()
        window = nil
        tab.heldWebView = nil
        tab.webView = nil
    }
}

private struct BrowserAutomaticTabClosure {
    let message: String
    let closedAt: Date
}

struct BrowserWebProcessUsage: Equatable {
    let processID: Int32
    let residentBytes: UInt64
}

private enum BrowserWebProcessMonitor {
    static func usage(_ webView: WKWebView) -> BrowserWebProcessUsage? {
        // WebKit exposes no public per-WKWebView memory API. This longstanding
        // selector is used only to identify the WebContent process; memory itself
        // comes from the public proc_pid_rusage API. If the selector disappears,
        // expiry remains active and memory enforcement safely becomes unavailable.
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let number = webView.value(forKey: "_webProcessIdentifier") as? NSNumber else {
            return nil
        }
        let processID = number.int32Value
        guard processID > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: MemoryLayout<rusage_info_v4>.size / MemoryLayout<rusage_info_t?>.size
            ) { rebound in
                proc_pid_rusage(processID, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return BrowserWebProcessUsage(processID: processID,
                                      residentBytes: info.ri_phys_footprint)
    }
}

/// Offscreen hosts are render surfaces only. They deliberately cannot become key
/// or receive pointer input; hidden automation is isolated inside its WKWebView.
private final class BrowserOffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct BrowserEncodedScreenshot: Sendable {
    let base64: String
    let width: Int
    let height: Int
}

enum ArgusWindowCapture {
    static func captureMainWindow() throws -> CGImage {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == ArgusWindowIdentity.main && $0.windowNumber > 0
        }) else {
            throw BrowserControlFailure.failed("the Argus main window is unavailable")
        }

        guard let view = window.contentView else {
            throw BrowserControlFailure.failed("the Argus main-window content is unavailable")
        }
        return try renderViewTree(view, scale: window.backingScaleFactor)
    }

    /// Render only Argus's in-process Core Animation tree. Unlike AppKit's display
    /// cache path, this never asks WindowServer to copy a composed window, so remote
    /// WebKit surfaces cannot turn an app screenshot into a Screen Recording prompt.
    /// A remote surface may be absent from this image; browser tabs have their own
    /// `WKWebView.takeSnapshot` path and must be captured through that API instead.
    static func renderViewTree(_ view: NSView, scale requestedScale: CGFloat) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else {
            throw BrowserControlFailure.failed("the Argus main-window layer tree is unavailable")
        }
        let bounds = view.bounds
        let scale = max(requestedScale, 1)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw BrowserControlFailure.failed("Argus could not allocate its window snapshot")
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        layer.render(in: context)
        guard let image = context.makeImage() else {
            throw BrowserControlFailure.failed("Argus could not encode its window snapshot")
        }
        return image
    }
}

private enum BrowserScreenshotEncoder {
    static func encode(_ image: CGImage) async throws -> BrowserEncodedScreenshot {
        try await Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw BrowserControlFailure.failed("could not create the PNG encoder")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw BrowserControlFailure.failed("could not encode the WebKit screenshot")
            }
            return BrowserEncodedScreenshot(base64: (data as Data).base64EncodedString(),
                                            width: image.width, height: image.height)
        }.value
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

    func callAsync(script: String, arguments: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result)
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
        const type = (el.getAttribute('type') || '').toLowerCase();
        const isFileInput = el instanceof HTMLInputElement && type === 'file';
        const isVisible = visible(el);
        // Hidden file inputs back many visible upload buttons. Include them so
        // an agent can address the real picker by ref without opening AppKit.
        if ((!isVisible && !isFileInput) || elements.length >= 750) continue;
        let ref = el.getAttribute('data-argus-browser-ref');
        if (!ref) {
          ref = 'e' + (++window.__argusBrowserRef);
          el.setAttribute('data-argus-browser-ref', ref);
        }
        const r = el.getBoundingClientRect();
        const protectedValue = el.getAttribute('data-argus-protected-field') === 'true';
        const rawValue = ('value' in el && type !== 'password' && !protectedValue) ? String(el.value || '') : '';
        const name = el.getAttribute('aria-label') || el.getAttribute('title') ||
          el.getAttribute('placeholder') || el.getAttribute('name') ||
          el.innerText || el.textContent || (isFileInput ? 'File upload' : '');
        elements.push({
          ref, tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '',
          type, name: String(name).trim().replace(/\s+/g, ' ').slice(0, 300),
          value: rawValue.slice(0, 1000), disabled: !!el.disabled, visible: isVisible,
          accept: isFileInput ? String(el.accept || '') : '',
          multiple: isFileInput ? !!el.multiple : false,
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

    // Credential values use native WebKit text input and never enter page
    // JavaScript. This best-effort marker only redacts a reachable field from
    // later semantic snapshots; cross-origin and closed-shadow fields are already
    // outside the top document's observation boundary.
    static let markProtectedField = #"""
    let el = null;
    if (typeof targetRef === 'string') {
      el = [...document.querySelectorAll('[data-argus-browser-ref]')]
        .find(node => node.getAttribute('data-argus-browser-ref') === targetRef) || null;
    } else if (Number.isFinite(targetX) && Number.isFinite(targetY)) {
      el = document.elementFromPoint(targetX, targetY);
    }
    if (!el) return false;
    el.setAttribute('data-argus-protected-field', 'true');
    return true;
    """#

    // File bytes arrive through WebKit's argument channel and become browser
    // File objects. This is the page-level equivalent of a user choosing files;
    // it never presents NSOpenPanel or changes macOS application focus.
    static let attachFiles = #"""
    const payloads = Array.isArray(uploadFiles) ? uploadFiles : [];
    const byRef = (ref) => [...document.querySelectorAll('[data-argus-browser-ref]')]
      .find(node => node.getAttribute('data-argus-browser-ref') === ref) || null;
    let target = typeof targetRef === 'string' ? byRef(targetRef) : null;
    if (!target && Number.isFinite(targetX) && Number.isFinite(targetY)) {
      target = document.elementFromPoint(targetX, targetY);
    }
    const asFileInput = (node) => {
      if (!node) return null;
      if (node instanceof HTMLInputElement && node.type === 'file') return node;
      if (node instanceof HTMLLabelElement && node.control instanceof HTMLInputElement &&
          node.control.type === 'file') return node.control;
      const label = node.closest?.('label');
      if (label?.control instanceof HTMLInputElement && label.control.type === 'file') {
        return label.control;
      }
      const descendant = node.querySelector?.('input[type="file"]');
      if (descendant) return descendant;
      let scope = node.parentElement;
      for (let depth = 0; scope && depth < 3; depth++, scope = scope.parentElement) {
        const nearby = [...scope.querySelectorAll('input[type="file"]')];
        if (nearby.length === 1) return nearby[0];
      }
      return null;
    };
    let input = asFileInput(target);
    if (!input && !target) {
      const candidates = [...document.querySelectorAll('input[type="file"]')];
      if (candidates.length === 1) input = candidates[0];
      else if (candidates.length > 1) {
        return {ok:false, error:'the page has multiple file inputs; use --ref or --at'};
      }
    }
    if (!(input instanceof HTMLInputElement) || input.type !== 'file') {
      return {ok:false, error:'no file input matches the requested target'};
    }
    if (input.disabled) return {ok:false, error:'the file input is disabled'};
    if (!input.multiple && payloads.length > 1) {
      return {ok:false, error:'the file input accepts only one file'};
    }
    try {
      const transfer = new DataTransfer();
      for (const payload of payloads) {
        const binary = atob(String(payload.dataBase64 || ''));
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index++) {
          bytes[index] = binary.charCodeAt(index);
        }
        transfer.items.add(new File([bytes], String(payload.name || 'upload'), {
          type: String(payload.mimeType || 'application/octet-stream'),
          lastModified: Number(payload.lastModified || Date.now())
        }));
      }
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files')?.set;
      if (setter) setter.call(input, transfer.files); else input.files = transfer.files;
      input.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
      input.dispatchEvent(new Event('change', {bubbles:true, composed:true}));
      return {ok:true, names:[...input.files].map(file => file.name)};
    } catch (error) {
      return {ok:false, error:String(error?.message || error || 'file attachment failed')};
    }
    """#

    static let typeIntoContentEditable = #"""
    const editableSelector = '[contenteditable]:not([contenteditable="false"])';
    const byRef = (ref) => [...document.querySelectorAll('[data-argus-browser-ref]')]
      .find(node => node.getAttribute('data-argus-browser-ref') === ref) || null;
    let target = typeof targetRef === 'string' ? byRef(targetRef) : null;
    if (!target && Number.isFinite(targetX) && Number.isFinite(targetY)) {
      target = document.elementFromPoint(targetX, targetY);
    }
    if (!target && targetRef == null && !Number.isFinite(targetX)) {
      target = document.activeElement;
    }
    const editor = target?.matches?.(editableSelector)
      ? target : target?.closest?.(editableSelector);
    if (!(editor instanceof HTMLElement) || !editor.isContentEditable) {
      return {handled:false};
    }
    try {
      const text = String(insertedText ?? '');
      if (text.length === 0) return {handled:true, ok:true};
      const fragment = editor.ownerDocument.createDocumentFragment();
      text.split('\n').forEach((line, index) => {
        if (index > 0) fragment.appendChild(editor.ownerDocument.createElement('br'));
        if (line.length > 0) fragment.appendChild(editor.ownerDocument.createTextNode(line));
      });
      editor.appendChild(fragment);
      let inputEvent;
      try {
        inputEvent = new InputEvent('input', {
          bubbles:true, composed:true, data:text, inputType:'insertText'
        });
      } catch (_) {
        inputEvent = new Event('input', {bubbles:true, composed:true});
      }
      try { editor.dispatchEvent(inputEvent); } catch (_) {}
      return {handled:true, ok:true};
    } catch (error) {
      return {handled:true, ok:false, error:String(error?.message || error || 'typing failed')};
    }
    """#

    static func coordinateClick(x: Double, y: Double) -> String {
        return #"""
        (() => {
          const x = \#(x), y = \#(y);
          const el = document.elementFromPoint(x, y);
          if (!el) return false;

          // A native HTMLSelectElement opens an AppKit popup outside WKWebView's
          // composited page, so takeSnapshot cannot see it. Mirror that one popup
          // inside the page: screenshots and subsequent coordinate/ref clicks then
          // describe the same state, while the selected value is still written to
          // the real element and its normal input/change handlers are fired.
          const overlayID = '__argus-browser-select-overlay';
          const existingOverlay = document.getElementById(overlayID);
          const optionRow = el.closest?.('[data-argus-select-index]');
          if (existingOverlay && optionRow && existingOverlay.contains(optionRow)) {
            const selectRef = existingOverlay.getAttribute('data-argus-select-ref');
            const select = [...document.querySelectorAll('select[data-argus-browser-ref]')]
              .find(node => node.getAttribute('data-argus-browser-ref') === selectRef);
            const index = Number(optionRow.getAttribute('data-argus-select-index'));
            if (!(select instanceof HTMLSelectElement) || !Number.isInteger(index) ||
                !select.options[index] || select.options[index].disabled) return false;
            const setter = Object.getOwnPropertyDescriptor(
              HTMLSelectElement.prototype, 'selectedIndex'
            )?.set;
            if (setter) setter.call(select, index); else select.selectedIndex = index;
            select.focus({preventScroll:true});
            select.dispatchEvent(new Event('input', {bubbles:true}));
            select.dispatchEvent(new Event('change', {bubbles:true}));
            existingOverlay.remove();
            return true;
          }

          if (existingOverlay) existingOverlay.remove();
          if (el instanceof HTMLSelectElement) {
            window.__argusBrowserRef = window.__argusBrowserRef || 0;
            let selectRef = el.getAttribute('data-argus-browser-ref');
            if (!selectRef) {
              selectRef = 'e' + (++window.__argusBrowserRef);
              el.setAttribute('data-argus-browser-ref', selectRef);
            }
            const selectRect = el.getBoundingClientRect();
            const computed = getComputedStyle(el);
            const dark = matchMedia('(prefers-color-scheme: dark)').matches;
            const overlay = document.createElement('div');
            overlay.id = overlayID;
            overlay.setAttribute('data-argus-select-ref', selectRef);
            overlay.setAttribute('role', 'listbox');
            overlay.setAttribute('aria-label', el.getAttribute('aria-label') || el.name || 'Options');
            Object.assign(overlay.style, {
              all: 'initial', position: 'fixed', zIndex: '2147483647', boxSizing: 'border-box',
              minWidth: Math.max(selectRect.width, 180) + 'px',
              maxWidth: Math.max(220, Math.min(innerWidth - 16, 560)) + 'px',
              maxHeight: Math.max(120, Math.min(innerHeight - 16, 420)) + 'px',
              overflowY: 'auto', overflowX: 'hidden',
              color: dark ? '#f4f4f5' : '#18181b', background: dark ? '#242428' : '#ffffff',
              border: '1px solid ' + (dark ? '#5b5b63' : '#a1a1aa'), borderRadius: '7px',
              boxShadow: '0 10px 30px rgba(0,0,0,.28)', padding: '4px',
              font: computed.font || '13px -apple-system, BlinkMacSystemFont, sans-serif',
              lineHeight: '1.35', textAlign: 'left'
            });
            [...el.options].forEach((option, index) => {
              const row = document.createElement('div');
              row.setAttribute('role', 'option');
              row.setAttribute('aria-selected', option.selected ? 'true' : 'false');
              row.setAttribute('data-argus-select-index', String(index));
              row.textContent = option.label || option.textContent || option.value;
              Object.assign(row.style, {
                all: 'initial', display: 'block', boxSizing: 'border-box', padding: '7px 10px',
                borderRadius: '4px', whiteSpace: 'normal', overflowWrap: 'anywhere',
                color: option.disabled ? (dark ? '#77777f' : '#a1a1aa') :
                  (option.selected ? (dark ? '#ffffff' : '#111827') : (dark ? '#f4f4f5' : '#18181b')),
                background: option.selected ? (dark ? '#245ea8' : '#dbeafe') : 'transparent',
                font: computed.font || '13px -apple-system, BlinkMacSystemFont, sans-serif',
                lineHeight: '1.35', cursor: option.disabled ? 'default' : 'pointer'
              });
              overlay.appendChild(row);
            });
            document.documentElement.appendChild(overlay);
            const overlayRect = overlay.getBoundingClientRect();
            const roomBelow = innerHeight - selectRect.bottom - 8;
            const top = roomBelow >= Math.min(overlayRect.height, 160)
              ? selectRect.bottom + 3 : Math.max(8, selectRect.top - overlayRect.height - 3);
            overlay.style.left = Math.max(8, Math.min(selectRect.left, innerWidth - overlayRect.width - 8)) + 'px';
            overlay.style.top = Math.max(8, Math.min(top, innerHeight - overlayRect.height - 8)) + 'px';
            overlay.querySelector('[aria-selected="true"]')?.scrollIntoView({block:'nearest'});
            return true;
          }

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

    static func focus(ref: String) -> String {
        let encoded = jsString(ref)
        return #"""
        (() => {
          const referenced = [...document.querySelectorAll('[data-argus-browser-ref]')]
            .find(node => node.getAttribute('data-argus-browser-ref') === \#(encoded));
          if (!referenced) return false;
          const selector = 'input,textarea,[contenteditable]:not([contenteditable="false"])';
          const el = referenced.matches?.(selector) ? referenced : referenced.closest?.(selector);
          if (!el || el.disabled || el.readOnly) return false;
          el.scrollIntoView({block:'center', inline:'center'});
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
          return false;
        })()
        """#
    }

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
      return false;
    })()
    """#

    static func scroll(dx: Double, dy: Double) -> String {
        "window.scrollBy({left:\(dx), top:\(dy), behavior:'instant'}); true"
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
            if accumulated.count > 64 * 1024 * 1024 {
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
