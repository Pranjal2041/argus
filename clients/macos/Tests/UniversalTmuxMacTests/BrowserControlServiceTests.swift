import Foundation
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class BrowserControlServiceTests: XCTestCase {
    func testHiddenWebKitTabSupportsScreenshotIsolatedInputAndPromotion() async throws {
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                         persistTabState: false)
        // Native input remains enabled globally, but hidden tabs must always use
        // their isolated DOM-coordinate path and never enter Argus's event queue.
        let service = BrowserControlService(nativeInputEnabled: true)
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
        XCTAssertEqual(typedObservation["interaction_mode"] as? String, "dom-coordinate-fallback")
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
        XCTAssertEqual(observation["interaction_mode"] as? String, "dom-coordinate-fallback")
        let clickedSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertTrue((clickedSnapshot["text"] as? String ?? "").contains("Clicked"))

        let scrolledObservation = try await rpc(service, method: "page.scroll", params: [
            "tab_id": tabID, "dx": 0, "dy": 400
        ])
        XCTAssertEqual(scrolledObservation["interaction_mode"] as? String, "dom-coordinate-fallback")
        let scrolledSnapshot = try await rpc(service, method: "page.snapshot", params: ["tab_id": tabID])
        XCTAssertGreaterThan(number(try XCTUnwrap(scrolledSnapshot["scroll"] as? [String: Any]), "y"), 0)

        let beforePromotion = try XCTUnwrap(observation["tab_id"] as? String)
        let shown = try await rpc(service, method: "tabs.show", params: ["tab_id": tabID])
        XCTAssertEqual(shown["id"] as? String, beforePromotion)
        XCTAssertEqual(dashboards.tabs.count, 1)
        XCTAssertEqual(dashboards.tabs.first?.id.uuidString.lowercased(), tabID)
        XCTAssertNotNil(dashboards.tabs.first?.heldWebView)
    }

    func testNativeInputPolicyRequiresExactForegroundBrowserTab() {
        XCTAssertTrue(BrowserNativeInputPolicy.allowsNativeInput(
            enabled: true, tabIsHidden: false, applicationIsActive: true,
            tabIsSelected: true, windowIsKey: true, windowIsVisible: true
        ))

        let unsafeCases: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, true, true, true, true),  // feature disabled
            (true, true, true, true, true, true),    // hidden agent tab
            (true, false, false, true, true, true),  // Argus is backgrounded
            (true, false, true, false, true, true),  // another browser tab selected
            (true, false, true, true, false, true),  // another window is key
            (true, false, true, true, true, false),  // dashboard window is not visible
        ]
        for values in unsafeCases {
            XCTAssertFalse(BrowserNativeInputPolicy.allowsNativeInput(
                enabled: values.0, tabIsHidden: values.1,
                applicationIsActive: values.2, tabIsSelected: values.3,
                windowIsKey: values.4, windowIsVisible: values.5
            ))
        }
    }

    private func rpc(_ service: BrowserControlService, method: String,
                     params: [String: Any]) async throws -> [String: Any] {
        let request: [String: Any] = ["version": 1, "id": UUID().uuidString,
                                      "method": method, "params": params]
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
