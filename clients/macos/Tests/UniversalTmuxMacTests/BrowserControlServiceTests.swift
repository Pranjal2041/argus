import Foundation
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class BrowserControlServiceTests: XCTestCase {
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
        XCTAssertEqual(typedObservation["interaction_mode"] as? String, "dom-injected")
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
        XCTAssertEqual(observation["interaction_mode"] as? String, "dom-injected")
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

    private func rpc(_ service: BrowserControlService, method: String,
                     params: [String: Any], caller: [String: Any]? = nil) async throws -> [String: Any] {
        var request: [String: Any] = ["version": 1, "id": UUID().uuidString,
                                          "method": method, "params": params]
        if let caller { request["caller"] = caller }
        let body = try JSONSerialization.data(withJSONObject: request)
        let responseData = await service.processRPCForTesting(body)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        if response["ok"] as? Bool != true {
            XCTFail(response["error"] as? String ?? "browser RPC failed")
        }
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func number(_ dictionary: [String: Any], _ key: String) -> Double {
        (dictionary[key] as? NSNumber)?.doubleValue ?? 0
    }
}
