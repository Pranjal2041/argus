import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class PlannerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(day: Int = 4, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    func testChronologicalOrderIgnoresStatusAndPutsEndOfDayLast() {
        var atTwo = PlannerCommitment(title: "two", deadline: date(hour: 14))
        atTwo.completedAt = date(hour: 14, minute: 5)
        let atTen = PlannerCommitment(title: "ten", deadline: date(hour: 10))
        let atFiveThirty = PlannerCommitment(title: "five-thirty", deadline: date(hour: 17, minute: 30))
        let endOfDay = PlannerCommitment(
            title: "end-of-day",
            deadline: date(hour: 0),
            hasExactTime: false
        )

        let sorted = [endOfDay, atFiveThirty, atTwo, atTen].sorted {
            PlannerCommitment.chronologicallyBefore($0, $1, calendar: calendar)
        }

        XCTAssertEqual(sorted.map(\.title), ["ten", "two", "five-thirty", "end-of-day"])
    }

    func testNewCommitmentsDefaultToTodayAtElevenFiftyNinePM() {
        let now = date(day: 4, hour: 8, minute: 17)
        let deadline = PlannerDefaults.deadline(now: now, calendar: calendar)

        XCTAssertTrue(calendar.isDate(deadline, inSameDayAs: now))
        XCTAssertEqual(calendar.component(.hour, from: deadline), 23)
        XCTAssertEqual(calendar.component(.minute, from: deadline), 59)
        XCTAssertEqual(calendar.component(.second, from: deadline), 0)
    }

    func testProjectSuggestionsFilterAsYouTypeAndRankPrefixesFirst() {
        let projects = [
            "spatial_fable", "VLM_gating", "fable_archive", "SPATIAL_FABLE", "spatial_sol",
        ]

        XCTAssertEqual(
            PlannerProjectSuggestions.filtered(projects, query: "spa"),
            ["spatial_fable", "spatial_sol"]
        )
        XCTAssertEqual(
            PlannerProjectSuggestions.filtered(projects, query: "fable"),
            ["fable_archive", "spatial_fable"]
        )
    }

    func testPlannerFilterCatalogContainsOnlyProjectsWithPlansAndCollapsesCaseVariants() {
        let commitments = [
            PlannerCommitment(title: "One", project: "vlm_gating", deadline: date(hour: 10)),
            PlannerCommitment(title: "Two", project: "VLM_GATING", deadline: date(hour: 11)),
            PlannerCommitment(title: "Three", project: "spatial_fable", deadline: date(hour: 12)),
            PlannerCommitment(title: "Unscoped", deadline: date(hour: 13)),
        ]

        let options = PlannerProjectCatalog.options(from: commitments, preserving: "")

        XCTAssertEqual(options.map(\.name), ["spatial_fable", "vlm_gating"])
        XCTAssertEqual(options.map(\.count), [1, 2])
        XCTAssertFalse(options.contains { $0.name == "unrelated_live_shell" })
    }

    func testPlannerMutationsPreserveARealDeadlineAndCompletionHistory() {
        let state = AppState(isolatedForTesting: true)
        state.plannerCommitments = []

        let id = state.addPlannerCommitment(
            title: "  Finish the report  ",
            project: "  vlm_gating ",
            deadline: date(day: 5, hour: 12),
            hasExactTime: true
        )
        XCTAssertNotNil(id)
        XCTAssertEqual(state.plannerCommitments.first?.title, "Finish the report")
        XCTAssertEqual(state.plannerCommitments.first?.project, "vlm_gating")

        state.togglePlannerCommitment(id!)
        XCTAssertNotNil(state.plannerCommitments.first?.completedAt)
        state.togglePlannerCommitment(id!)
        XCTAssertNil(state.plannerCommitments.first?.completedAt)

        state.updatePlannerCommitment(
            id!,
            title: "Finish the final report",
            project: "vlm_gating",
            deadline: date(day: 6, hour: 16),
            hasExactTime: false
        )
        let updated = state.plannerCommitments[0]
        XCTAssertEqual(updated.title, "Finish the final report")
        XCTAssertFalse(updated.hasExactTime)
        XCTAssertTrue(calendar.isDate(updated.deadline, inSameDayAs: date(day: 6)))
        XCTAssertEqual(Calendar.current.component(.hour, from: updated.deadline), 0)

        state.deletePlannerCommitment(id!)
        XCTAssertTrue(state.plannerCommitments.isEmpty)
    }

    func testPresentPlannerMakesItTheOnlyTopLevelPane() {
        let state = AppState(isolatedForTesting: true)
        state.showOverview = true
        state.showTodos = true
        state.showNotes = true
        state.showLedger = true
        state.showLab = true
        state.showArtifacts = true

        state.presentPlanner()

        XCTAssertTrue(state.showPlanner)
        XCTAssertFalse(state.showOverview)
        XCTAssertFalse(state.showTodos)
        XCTAssertFalse(state.showNotes)
        XCTAssertFalse(state.showLedger)
        XCTAssertFalse(state.showLab)
        XCTAssertFalse(state.showArtifacts)
    }

    func testPlannerViewCanRenderAtTheMinimumUsefulDetailWidth() {
        let state = AppState(isolatedForTesting: true)
        state.plannerCommitments = [
            PlannerCommitment(
                title: "Finish the router ablation write-up",
                project: "vlm_gating",
                deadline: date(day: 5, hour: 12)
            )
        ]
        let host = NSHostingView(rootView: PlannerView().environmentObject(state))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 760)

        host.layoutSubtreeIfNeeded()

        if ProcessInfo.processInfo.environment["UT_CAPTURE_PLANNER_TEST"] == "1",
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/argus-planner-native.png"))
        }

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testPlannerViewCanRenderAtAWideDetailWidth() {
        let state = AppState(isolatedForTesting: true)
        state.plannerCommitments = [
            PlannerCommitment(
                title: "Finish the router ablation write-up",
                project: "vlm_gating",
                deadline: date(day: 5, hour: 12)
            ),
            PlannerCommitment(
                title: "Choose the final benchmark shortlist",
                project: "spatial_fable",
                deadline: date(day: 5, hour: 18)
            ),
        ]
        let host = NSHostingView(rootView: PlannerView().environmentObject(state))
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 760)

        host.layoutSubtreeIfNeeded()

        if ProcessInfo.processInfo.environment["UT_CAPTURE_PLANNER_TEST"] == "1",
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/argus-planner-wide.png"))
        }

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testPlannerViewCanRenderWithoutOverflowAtANarrowSidebarDetailWidth() {
        let state = AppState(isolatedForTesting: true)
        state.plannerCommitments = [
            PlannerCommitment(
                title: "Finish the router ablation write-up",
                project: "vlm_gating",
                deadline: date(day: 5, hour: 12)
            ),
            PlannerCommitment(
                title: "Review the environment specification",
                project: "gym-anything",
                deadline: date(day: 5, hour: 17, minute: 30)
            ),
        ]
        let host = NSHostingView(rootView: PlannerView().environmentObject(state))
        host.frame = NSRect(x: 0, y: 0, width: 470, height: 900)

        host.layoutSubtreeIfNeeded()

        if ProcessInfo.processInfo.environment["UT_CAPTURE_PLANNER_TEST"] == "1",
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/argus-planner-narrow.png"))
        }

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertEqual(host.frame.width, 470)
    }
}
