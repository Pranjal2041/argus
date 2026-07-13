import Foundation
import XCTest
@testable import UniversalTmuxMac

final class DashboardNavigationFailurePolicyTests: XCTestCase {
    func testNativeMediaHandoffIsTreatedAsLoadedContent() {
        let error = NSError(domain: "WebKitErrorDomain", code: 204)

        XCTAssertEqual(DashboardNavigationFailurePolicy.disposition(for: error), .contentHandled)
    }

    func testCancelledURLLoadIsASupersededNavigation() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        XCTAssertEqual(DashboardNavigationFailurePolicy.disposition(for: error), .superseded)
    }

    func testTransientEndpointFailuresAreRetryable() {
        let codes = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorNotConnectedToInternet,
        ]

        for code in codes {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(DashboardNavigationFailurePolicy.disposition(for: error), .retryable,
                           "expected URL error \(code) to be retryable")
        }
    }

    func testPermanentAndUnrelatedFailuresAreReportedImmediately() {
        let certificate = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let webKit = NSError(domain: "WebKitErrorDomain", code: 203)
        let unrelatedCancellationCode = NSError(domain: "OtherDomain", code: NSURLErrorCancelled)

        XCTAssertEqual(DashboardNavigationFailurePolicy.disposition(for: certificate), .report)
        XCTAssertEqual(DashboardNavigationFailurePolicy.disposition(for: webKit), .report)
        XCTAssertEqual(DashboardNavigationFailurePolicy.disposition(for: unrelatedCancellationCode), .report)
    }
}
