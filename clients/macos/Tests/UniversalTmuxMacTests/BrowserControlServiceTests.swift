import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class BrowserControlServiceTests: XCTestCase {
    func testArgusWindowCaptureRendersTheOwnedLayerTree() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 24))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor

        let image = try ArgusWindowCapture.renderViewTree(view, scale: 2)

        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 48)
    }

    func testBrowserConfigurationBlocksDisplayCaptureBeforePageCodeRuns() {
        let configuration = ArgusBrowserIdentity.persistentConfiguration()
        let scripts = configuration.userContentController.userScripts

        XCTAssertTrue(scripts.contains {
            $0.injectionTime == .atDocumentStart &&
            !$0.isForMainFrameOnly &&
            $0.source.contains("getDisplayMedia") &&
            $0.source.contains("NotAllowedError")
        })
    }

    func testRemoteWebDelegateDeniesDisplayCaptureInWebKitUIProcess() {
        let delegate = ArgusRemoteWebUIDelegate()
        let selector = NSSelectorFromString(
            "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:"
        )

        XCTAssertTrue(delegate.responds(to: selector))
    }

    func testArgusWindowScreenshotReturnsPNGFromAppOwnedCapture() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let service = BrowserControlService(appWindowCapture: { image })
        service.bindForTesting(dashboards: dashboards)

        let result = try await rpc(service, method: "app.screenshot", params: [:])
        XCTAssertEqual(result["scope"] as? String, "argus-window")
        XCTAssertEqual(result["mime_type"] as? String, "image/png")
        XCTAssertEqual(result["width"] as? Int, 48)
        XCTAssertEqual(result["height"] as? Int, 32)
        let encoded = try XCTUnwrap(result["image_base64"] as? String)
        let png = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testBrowserTabsAdvertiseTheInstalledSafariIdentity() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)
        let html = """
        <!doctype html><meta charset="utf-8">
        <body><script>document.body.textContent = navigator.userAgent</script></body>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()

        let opened = try await rpc(service, method: "tabs.open", params: ["url": dataURL])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let snapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let userAgent = snapshot["text"] as? String ?? ""

        XCTAssertTrue(userAgent.contains("AppleWebKit/"), userAgent)
        XCTAssertTrue(userAgent.contains("Version/\(ArgusBrowserIdentity.safariVersion)"), userAgent)
        XCTAssertTrue(userAgent.contains("Safari/605.1.15"), userAgent)
    }

    func testHiddenWebKitTabSupportsScreenshotIsolatedInputAndPromotion() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)
        let html = """
        <!doctype html><meta charset="utf-8">
        <style>body{margin:0;font:20px sans-serif;height:1600px}input,button{margin:30px;padding:12px}</style>
        <input aria-label="Name" value=""><button onclick="this.textContent='Clicked'">Press me</button>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()

        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": dataURL, "visible": false, "width": 900, "height": 600
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        XCTAssertEqual(opened["visible"] as? Bool, false)
        XCTAssertTrue(dashboards.tabs.isEmpty)

        // macOS can move an ordered offscreen host back onto a screen during
        // Space/full-screen transitions. Reproduce that exact failure: the host
        // must remain fully invisible while the existing screenshot and native
        // input assertions below continue to pass.
        let host = try XCTUnwrap(service.repositionHiddenHostForTesting(
            tabID: tabID, to: CGPoint(x: 160, y: 0)
        ))
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.frame.origin.x, 160, accuracy: 0.1)
        XCTAssertEqual(host.frame.origin.y, 0, accuracy: 0.1)
        XCTAssertEqual(host.alpha, 0, accuracy: 0.0001)

        let firstSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let elements = try XCTUnwrap(firstSnapshot["elements"] as? [[String: Any]])
        let input = try XCTUnwrap(elements.first(where: { $0["name"] as? String == "Name" }))
        let button = try XCTUnwrap(elements.first(where: { $0["name"] as? String == "Press me" }))

        let inputRect = try XCTUnwrap(input["rect"] as? [String: Any])
        let typedObservation = try await rpc(service, method: "page.type", params: [
            "tab_id": tabID,
            "x": number(inputRect, "x") + 10,
            "y": number(inputRect, "y") + 10,
            "text": "Argus"
        ])
        XCTAssertEqual((typedObservation["width"] as? NSNumber)?.intValue, 900)
        XCTAssertEqual((typedObservation["height"] as? NSNumber)?.intValue, 600)
        XCTAssertEqual(typedObservation["interaction_mode"] as? String, "native-webkit")
        let typedSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let typedElements = try XCTUnwrap(typedSnapshot["elements"] as? [[String: Any]])
        XCTAssertEqual(typedElements.first(where: { $0["name"] as? String == "Name" })?["value"] as? String, "Argus")

        let buttonRect = try XCTUnwrap(button["rect"] as? [String: Any])
        let observation = try await rpc(service, method: "page.click", params: [
            "tab_id": tabID,
            "x": number(buttonRect, "x") + 10,
            "y": number(buttonRect, "y") + 10
        ])
        XCTAssertFalse((observation["image_base64"] as? String ?? "").isEmpty)
        XCTAssertEqual(observation["interaction_mode"] as? String, "native-webkit")
        let clickedSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((clickedSnapshot["text"] as? String ?? "").contains("Clicked"))

        let scrolledObservation = try await rpc(service, method: "page.scroll", params: [
            "tab_id": tabID, "dx": 0, "dy": 400
        ])
        XCTAssertEqual(scrolledObservation["interaction_mode"] as? String, "dom-injected")
        let scrolledSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertGreaterThan(number(try XCTUnwrap(scrolledSnapshot["scroll"] as? [String: Any]), "y"), 0)

        let beforePromotion = try XCTUnwrap(observation["tab_id"] as? String)
        let shown = try await rpc(service, method: "tabs.show", params: ["tab_id": tabID])
        XCTAssertEqual(shown["id"] as? String, beforePromotion)
        XCTAssertEqual(dashboards.tabs.count, 1)
        XCTAssertEqual(dashboards.tabs.first?.id.uuidString.lowercased(), tabID)
        XCTAssertNotNil(dashboards.tabs.first?.heldWebView)
    }

    func testNativeCoordinateInputReachesAHiddenChildFrame() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)
        let html = """
        <!doctype html><meta charset="utf-8">
        <style>html,body{margin:0}iframe{position:absolute;left:40px;top:40px;width:500px;height:280px;border:0}</style>
        <output id="result"></output><iframe id="login"></iframe>
        <script>
          const child = login.contentDocument;
          child.open();
          child.write(`<!doctype html><style>
            html,body{margin:0}input,button{position:absolute;left:40px;width:320px;height:50px}
            input{top:40px}button{top:120px}
          </style>
          <input aria-label="Framed name" oninput="parent.result.textContent='typed:'+this.value">
          <button onclick="parent.result.textContent='clicked'">Framed button</button>`);
          child.close();
        </script>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": dataURL, "visible": false, "width": 800, "height": 500
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let keyWindowBeforeInput = NSApp.keyWindow

        let initial = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((initial["elements"] as? [[String: Any]] ?? []).isEmpty,
                      "the main-frame DOM resolver deliberately cannot see iframe controls")

        let typed = try await rpc(service, method: "page.type", params: [
            "tab_id": tabID, "x": 100, "y": 100, "text": "Argus"
        ])
        XCTAssertEqual(typed["interaction_mode"] as? String, "native-webkit")
        let afterType = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((afterType["text"] as? String ?? "").contains("typed:Argus"))

        let clicked = try await rpc(service, method: "page.click", params: [
            "tab_id": tabID, "x": 100, "y": 180
        ])
        XCTAssertEqual(clicked["interaction_mode"] as? String, "native-webkit")
        let afterClick = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((afterClick["text"] as? String ?? "").contains("clicked"))
        XCTAssertTrue(dashboards.tabs.isEmpty, "native input must not reveal a hidden tab")
        XCTAssertTrue(NSApp.keyWindow === keyWindowBeforeInput,
                      "native input must not activate the hidden browser window")
    }

    func testNativeSelectOptionsRemainVisibleAndClickableInObservations() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)
        let html = """
        <!doctype html><meta charset="utf-8">
        <style>body{margin:30px;font:18px sans-serif}select{width:260px;height:40px}</style>
        <select aria-label="Dataset" onchange="document.body.dataset.chosen=this.value">
          <option value="alpha">Alpha set</option>
          <option value="beta">Beta set</option>
          <option value="gamma" disabled>Gamma set</option>
        </select>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": dataURL, "visible": false, "width": 800, "height": 500
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let initial = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let initialElements = try XCTUnwrap(initial["elements"] as? [[String: Any]])
        let selectRef = try XCTUnwrap(initialElements.first {
            $0["name"] as? String == "Dataset"
        }?["ref"] as? String)

        let openedMenu = try await rpc(service, method: "page.click", params: [
            "tab_id": tabID, "ref": selectRef
        ])
        XCTAssertFalse((openedMenu["image_base64"] as? String ?? "").isEmpty)
        XCTAssertEqual(openedMenu["interaction_mode"] as? String, "dom-injected")

        let menuSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let menuElements = try XCTUnwrap(menuSnapshot["elements"] as? [[String: Any]])
        let betaRef = try XCTUnwrap(menuElements.first {
            $0["role"] as? String == "option" && $0["name"] as? String == "Beta set"
        }?["ref"] as? String)
        _ = try await rpc(service, method: "page.click", params: [
            "tab_id": tabID, "ref": betaRef
        ])

        let selected = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let selectedElements = try XCTUnwrap(selected["elements"] as? [[String: Any]])
        XCTAssertEqual(selectedElements.first {
            $0["name"] as? String == "Dataset"
        }?["value"] as? String, "beta")
        XCTAssertFalse(selectedElements.contains { $0["role"] as? String == "option" })
    }

    func testVisibleAgentTabIsAddedWithoutReplacingTheActiveDashboardTab() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let active = dashboards.openURL("data:text/html,User%20tab")
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)

        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": "data:text/html,Agent%20tab", "visible": true
        ])

        XCTAssertEqual(opened["visible"] as? Bool, true)
        XCTAssertEqual(dashboards.tabs.count, 2)
        XCTAssertEqual(dashboards.activeID, active.id,
                       "agent tab creation must not switch the user's active tab")
    }

    func testHiddenTabExpiresWithAnExplicitAgentError() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let service = BrowserControlService(
            hiddenTabLifetime: 12 * 60 * 60,
            now: { clock },
            webProcessUsage: { _ in nil }
        )
        service.bindForTesting(dashboards: dashboards)
        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": "data:text/html,temporary", "visible": false
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        XCTAssertNotNil(opened["hidden_expires_at"] as? String)

        clock.addTimeInterval(12 * 60 * 60 + 1)
        service.runLifecycleWatchdogForTesting()

        let response = try await rawRPC(service, method: "page.snapshot",
                                        params: ["tab_id": tabID])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue((response["error"] as? String ?? "").contains("12-hour lifetime limit"))
    }

    func testHiddenTabMemoryLimitClosesItWhileVisibleTabsAreExempt() async throws {
        let limit: UInt64 = 4 * 1_024 * 1_024 * 1_024
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService(
            hiddenTabMemoryLimit: limit,
            webProcessUsage: { _ in
                BrowserWebProcessUsage(processID: 42, residentBytes: limit + 1)
            }
        )
        service.bindForTesting(dashboards: dashboards)
        let hidden = try await rpc(service, method: "tabs.open", params: [
            "url": "data:text/html,hidden", "visible": false
        ])
        let visible = try await rpc(service, method: "tabs.open", params: [
            "url": "data:text/html,visible", "visible": true
        ])
        let hiddenID = try XCTUnwrap(hidden["id"] as? String)
        let visibleID = try XCTUnwrap(visible["id"] as? String)

        service.runLifecycleWatchdogForTesting()

        let closed = try await rawRPC(service, method: "page.snapshot",
                                      params: ["tab_id": hiddenID])
        XCTAssertEqual(closed["ok"] as? Bool, false)
        XCTAssertTrue((closed["error"] as? String ?? "").contains("exceeding the 4.00 GiB limit"))
        _ = try await rpc(service, method: "page.snapshot", params: ["tab_id": visibleID])
    }

    func testProductionWebProcessSamplerCanMeasureALoadedHiddenTab() async throws {
        let service = BrowserControlService(hiddenTabMemoryLimit: 1)
        service.bindForTesting(
            dashboards: DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                        persistTabState: false)
        )
        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": "data:text/html,measured", "visible": false
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)

        service.runLifecycleWatchdogForTesting()

        let response = try await rawRPC(service, method: "page.snapshot",
                                        params: ["tab_id": tabID])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue((response["error"] as? String ?? "").contains("WebKit content process used"))
    }

    func testAgentUploadAttachesFileWithoutOpeningNativePicker() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)
        let html = """
        <!doctype html><meta charset="utf-8">
        <style>input{display:none}</style>
        <label role="button" tabindex="0" aria-label="Choose attachment">
          Choose attachment
          <input name="attachment" type="file" accept=".txt" multiple
            onchange="result.textContent=[...this.files].map(f=>`${f.name}:${f.size}:${f.type}`).join(',')">
        </label>
        <output id="result"></output>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": dataURL, "visible": false, "width": 800, "height": 500
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let before = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let elements = try XCTUnwrap(before["elements"] as? [[String: Any]])
        let fileInput = try XCTUnwrap(elements.first { $0["type"] as? String == "file" })
        XCTAssertEqual(fileInput["visible"] as? Bool, false)
        XCTAssertEqual(fileInput["accept"] as? String, ".txt")
        XCTAssertEqual(fileInput["multiple"] as? Bool, true)
        let inputRef = try XCTUnwrap(fileInput["ref"] as? String)

        let name = "report's draft.txt"
        let contents = Data("browser-local upload".utf8)
        let observation = try await rpc(service, method: "page.upload", params: [
            "tab_id": tabID, "ref": inputRef,
            "files": [[
                "name": name, "mime_type": "text/plain",
                "data_base64": contents.base64EncodedString(),
                "last_modified_ms": 1_787_300_000_000
            ]]
        ])
        XCTAssertEqual(observation["uploaded"] as? [String], [name])
        XCTAssertEqual(observation["interaction_mode"] as? String, "dom-file-upload")

        let after = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((after["text"] as? String ?? "").contains("\(name):\(contents.count):text/plain"))
    }

    func testGmailStyleContentEditableSurvivesUnavailableLegacyEditingAPI() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards)
        let html = """
        <!doctype html><meta charset="utf-8">
        <script>
          document.execCommand = () => { throw new DOMException('legacy editing blocked') }
          Object.defineProperty(window, 'getSelection', {value: () => null})
        </script>
        <div role="textbox" aria-label="Message Body" contenteditable="true"
             onfocus="this.replaceWith(this.cloneNode(true))"
             oninput="result.textContent='input:' + this.innerText">
          <div style="height:120px">Existing formatted reply</div>
        </div>
        <output id="result"></output>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let opened = try await rpc(service, method: "tabs.open", params: [
            "url": dataURL, "visible": false, "width": 800, "height": 500
        ])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let snapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        let textboxRef = try XCTUnwrap(elements.first {
            $0["role"] as? String == "textbox"
        }?["ref"] as? String)

        let observation = try await rpc(service, method: "page.type", params: [
            "tab_id": tabID, "ref": textboxRef, "text": "First line\n\nSecond line"
        ])
        XCTAssertEqual(observation["interaction_mode"] as? String, "dom-contenteditable")
        let after = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let text = after["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Existing formatted reply"))
        XCTAssertTrue(text.contains("First line"))
        XCTAssertTrue(text.contains("Second line"))
        XCTAssertTrue(text.contains("input:"), "the page's normal input handler must run")
    }

    func testCredentialFillUsesProtectedWebKitPathAndRedactsInjectedFields() async throws {
        let suite = "BrowserCredentialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemoryCredentialSecretStore()
        let vault = CredentialVaultStore(secretStore: secrets, defaults: defaults)
        try vault.save(name: "Research Gmail", group: "Research",
                       username: "agent@example.com", password: "local-only-secret")
        vault.setAllowInUnattendedMode(true)
        vault.unattendedModeActive = true

        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards, credentialVault: vault)
        let html = """
        <!doctype html><meta charset="utf-8">
        <input aria-label="Email"><input aria-label="Password" type="password">
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let opened = try await rpc(service, method: "tabs.open", params: ["url": dataURL])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let snapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        let usernameRef = try XCTUnwrap(elements.first { $0["name"] as? String == "Email" }?["ref"] as? String)
        let passwordRef = try XCTUnwrap(elements.first { $0["name"] as? String == "Password" }?["ref"] as? String)
        let caller: [String: Any] = [
            "machine_name": "babel-p9-28", "machine_host": "babel-p9-28",
            "session_name": "research", "stable_session_id": "$4",
            "session_lineage_id": "tmux:lineage:$4"
        ]
        let granted = try await rpc(service, method: "credentials.request", params: [
            "credential": "Research Gmail", "tab_id": tabID
        ], caller: caller)
        let token = try XCTUnwrap(granted["grant"] as? String)
        let result = try await rpc(service, method: "credentials.fill", params: [
            "tab_id": tabID, "credential": "Research Gmail", "grant": token,
            "targets": ["username": ["ref": usernameRef], "password": ["ref": passwordRef]]
        ], caller: caller)
        XCTAssertEqual(Set(result["filled"] as? [String] ?? []), Set(["username", "password"]))

        let after = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        let afterElements = try XCTUnwrap(after["elements"] as? [[String: Any]])
        XCTAssertEqual(afterElements.first { $0["name"] as? String == "Email" }?["value"] as? String, "")
        XCTAssertEqual(afterElements.first { $0["name"] as? String == "Password" }?["value"] as? String, "")
        XCTAssertFalse((after["text"] as? String ?? "").contains("local-only-secret"))
    }

    func testCredentialFillCoordinatesReachClosedShadowPasswordField() async throws {
        let suite = "BrowserShadowCredentialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemoryCredentialSecretStore()
        let vault = CredentialVaultStore(secretStore: secrets, defaults: defaults)
        let password = "shadow-secret-742"
        try vault.save(name: "Shadow Login", group: "Test",
                       username: "", password: password)
        vault.setAllowInUnattendedMode(true)
        vault.unattendedModeActive = true

        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        let service = BrowserControlService()
        service.bindForTesting(dashboards: dashboards, credentialVault: vault)
        let html = """
        <!doctype html><meta charset="utf-8">
        <div id="host" style="width:320px;height:70px"></div><p id="result">empty</p>
        <script>
          const root = document.querySelector('#host').attachShadow({mode:'closed'});
          const input = document.createElement('input');
          input.type = 'password';
          input.style.cssText = 'display:block;width:280px;height:40px;margin:10px';
          input.addEventListener('input', () => {
            document.querySelector('#result').textContent = `length ${input.value.length}`;
          });
          root.append(input);
        </script>
        """
        let dataURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let opened = try await rpc(service, method: "tabs.open", params: ["url": dataURL])
        let tabID = try XCTUnwrap(opened["id"] as? String)
        let caller: [String: Any] = [
            "machine_name": "babel-p9-28", "machine_host": "babel-p9-28",
            "session_name": "research", "stable_session_id": "$4",
            "session_lineage_id": "tmux:lineage:$4"
        ]
        let granted = try await rpc(service, method: "credentials.request", params: [
            "credential": "Shadow Login", "tab_id": tabID
        ], caller: caller)
        let token = try XCTUnwrap(granted["grant"] as? String)
        let result = try await rpc(service, method: "credentials.fill", params: [
            "tab_id": tabID, "credential": "Shadow Login", "grant": token,
            "targets": ["password": ["x": 80, "y": 35]]
        ], caller: caller)
        XCTAssertEqual(result["filled"] as? [String], ["password"])

        let after = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((after["text"] as? String ?? "").contains("length \(password.count)"))
        XCTAssertFalse((after["text"] as? String ?? "").contains(password))
    }

    func testAPIKeyRequestUsesExactCallerDotenvAndNeverAppearsInCredentialList() async throws {
        let suite = "BrowserAPIKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CredentialVaultStore(secretStore: MemoryCredentialSecretStore(), defaults: defaults)
        try vault.saveAPIKey(name: "OpenAI research", group: "Research",
                             variable: "OPENAI_API_KEY", value: "sk-local-only")
        vault.setAllowInUnattendedMode(true)
        vault.unattendedModeActive = true
        let service = BrowserControlService()
        service.bindForTesting(
            dashboards: DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                        persistTabState: false),
            credentialVault: vault
        )
        let caller: [String: Any] = [
            "machine_name": "babel-p9-28", "machine_host": "babel-p9-28",
            "session_name": "research", "stable_session_id": "$4",
            "session_lineage_id": "tmux:lineage:$4",
            "working_directory": "/work/project", "dotenv_path": "/work/project/.env"
        ]
        let result = try await rpc(service, method: "api_keys.request",
                                   params: ["name": "openai research", "existing_variables": []],
                                   caller: caller)
        XCTAssertEqual(result["variable"] as? String, "OPENAI_API_KEY")
        XCTAssertEqual(result["value"] as? String, "sk-local-only")
        XCTAssertEqual(result["credential"] as? String, "OpenAI research")
        XCTAssertEqual(result["already_present"] as? Bool, false)

        let existing = try await rpc(service, method: "api_keys.request",
                                     params: ["name": "OpenAI research",
                                              "existing_variables": ["OPENAI_API_KEY"]],
                                     caller: caller)
        XCTAssertEqual(existing["variable"] as? String, "OPENAI_API_KEY")
        XCTAssertEqual(existing["credential"] as? String, "OpenAI research")
        XCTAssertEqual(existing["value"] as? String, "")
        XCTAssertEqual(existing["already_present"] as? Bool, true)

        let listed = try await rpc(service, method: "credentials.list", params: [:], caller: caller)
        XCTAssertTrue((listed["credentials"] as? [[String: Any]] ?? []).isEmpty,
                      "browser credential discovery must not reveal API-key records")
    }

    private func rpc(_ service: BrowserControlService, method: String,
                     params: [String: Any], caller: [String: Any]? = nil) async throws -> [String: Any] {
        let response = try await rawRPC(service, method: method, params: params, caller: caller)
        if response["ok"] as? Bool != true {
            XCTFail(response["error"] as? String ?? "browser RPC failed")
        }
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func rawRPC(_ service: BrowserControlService, method: String,
                        params: [String: Any], caller: [String: Any]? = nil) async throws -> [String: Any] {
        var request: [String: Any] = ["version": 1, "id": UUID().uuidString,
                                          "method": method, "params": params]
        if let caller { request["caller"] = caller }
        let body = try JSONSerialization.data(withJSONObject: request)
        let responseData = await service.processRPCForTesting(body)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func number(_ dictionary: [String: Any], _ key: String) -> Double {
        (dictionary[key] as? NSNumber)?.doubleValue ?? 0
    }
}
