import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class WeeklyProgressTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-weekly-progress-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = WeeklyProgressWeek.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testWeekAlwaysRunsMondayThroughFollowingMonday() {
        let sunday = date(day: 9, hour: 18)
        let week = WeeklyProgressWeek(containing: sunday, calendar: calendar)

        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
        XCTAssertEqual(calendar.dateComponents([.day], from: week.start, to: week.endExclusive).day, 7)
        XCTAssertEqual(calendar.component(.day, from: week.start), 3)
        XCTAssertEqual(calendar.component(.day, from: week.endExclusive), 10)
    }

    func testManualWeekNavigationMovesExactlySevenDays() {
        let week = WeeklyProgressWeek(containing: date(day: 9), calendar: calendar)
        let earlier = WeeklyProgressWeekNavigation.shifted(week, byWeeks: -3, calendar: calendar)
        let later = WeeklyProgressWeekNavigation.shifted(earlier, byWeeks: 3, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.day], from: earlier.start, to: week.start).day, 21)
        XCTAssertEqual(later.start, week.start)
        XCTAssertTrue(WeeklyProgressWeekNavigation.isCurrent(
            week,
            now: date(day: 9, hour: 12),
            calendar: calendar
        ))
    }

    func testProgressPresentationHasOneStableFourStepStory() {
        XCTAssertEqual(WeeklyProgressStagePresentation.activeStages, [
            .collectingEvidence, .reconstructingResearch, .draftingSlides, .auditingSlides,
        ])
        XCTAssertEqual(WeeklyProgressStagePresentation.completedSteps(for: .collectingEvidence), 0)
        XCTAssertEqual(WeeklyProgressStagePresentation.completedSteps(for: .draftingSlides), 2)
        XCTAssertEqual(WeeklyProgressStagePresentation.completedSteps(for: .complete), 4)
        XCTAssertEqual(WeeklyProgressStagePresentation.title(.auditingSlides), "Checking slides")
    }

    func testProjectEditorCatalogGroupsOnePanelAcrossMachines() {
        let machines = [
            Machine(id: "p9", name: "babel-p9-16", isLocal: false, httpBase: "", wsBase: ""),
            Machine(id: "n5", name: "babel-n5-24", isLocal: false, httpBase: "", wsBase: ""),
        ]
        let catalog = WeeklyProgressPanelCatalog.make(
            machines: machines,
            sessionsByMachine: [
                "p9": [SessionInfo(name: "vlm_gating", path: "/compute/p9/vlm")],
                "n5": [
                    SessionInfo(name: "VLM_GATING", path: "/compute/n5/vlm"),
                    SessionInfo(name: "helper", path: "/tmp/helper", agent: true),
                ],
            ]
        )

        XCTAssertEqual(catalog.count, 2)
        let gating = catalog.first { $0.session.caseInsensitiveCompare("vlm_gating") == .orderedSame }
        XCTAssertEqual(gating?.locations.map(\.machineName), ["babel-n5-24", "babel-p9-16"])
        XCTAssertEqual(Set(gating?.locations.compactMap(\.folder) ?? []), [
            "/compute/p9/vlm", "/compute/n5/vlm",
        ])
    }

    func testProjectEditorPastCatalogUsesDurableHistoryAndExcludesRunningPanels() throws {
        let machines = [
            Machine(
                id: "p9",
                name: "Babel P9",
                host: "babel-p9-16",
                isLocal: false,
                httpBase: "",
                wsBase: ""
            ),
            Machine(
                id: "n5",
                name: "Babel N5",
                host: "babel-n5-24",
                isLocal: false,
                httpBase: "",
                wsBase: ""
            ),
        ]
        let history = [
            SessionHistoryItem(
                name: "still_running",
                node: "babel-p9-16",
                folders: [FolderSpan(path: "/compute/live", first: 10, last: 400)],
                first: 10,
                last: 400
            ),
            SessionHistoryItem(
                name: "retired_eval",
                node: "babel-p9-16",
                folders: [FolderSpan(path: "/compute/p9/new", first: 250, last: 300)],
                first: 250,
                last: 300
            ),
            SessionHistoryItem(
                name: "RETIRED_EVAL",
                node: "babel-p9-16",
                folders: [FolderSpan(path: "/compute/p9/old", first: 100, last: 200)],
                first: 100,
                last: 200
            ),
            SessionHistoryItem(
                name: "retired_eval",
                node: "babel-n5-24",
                folders: [FolderSpan(path: "/compute/n5/eval", first: 150, last: 250)],
                first: 150,
                last: 250
            ),
            SessionHistoryItem(
                name: "older_panel",
                node: "offline-node",
                folders: [FolderSpan(path: "/scratch/old", first: 50, last: 100)],
                first: 50,
                last: 100
            ),
        ]

        let catalog = WeeklyProgressPanelCatalog.makePast(
            machines: machines,
            sessionsByMachine: [
                "p9": [SessionInfo(name: "STILL_RUNNING", path: "/compute/live")],
            ],
            historyItems: history
        )

        XCTAssertEqual(catalog.map(\.session), ["retired_eval", "older_panel"])
        XCTAssertTrue(catalog.allSatisfy { $0.availability == .past })
        let retired = try XCTUnwrap(catalog.first)
        XCTAssertEqual(retired.lastSeen, 300)
        XCTAssertEqual(retired.locations.map(\.machineID), ["p9", "n5"])
        XCTAssertEqual(Set(retired.locations.flatMap(\.folders)), [
            "/compute/p9/new", "/compute/p9/old", "/compute/n5/eval",
        ])
        XCTAssertFalse(catalog.contains {
            $0.session.caseInsensitiveCompare("still_running") == .orderedSame
        })
    }

    @MainActor
    func testWeeklyProgressNavigationExcludesEveryOtherTopLevelSurface() {
        let state = AppState(isolatedForTesting: true)
        state.showOverview = true
        state.showPlanner = true
        state.showTodos = true
        state.showNotes = true
        state.showLedger = true
        state.showLab = true
        state.showArtifacts = true

        state.presentWeeklyProgress()

        XCTAssertTrue(state.showWeeklyProgress)
        XCTAssertFalse(state.showOverview)
        XCTAssertFalse(state.showPlanner)
        XCTAssertFalse(state.showTodos)
        XCTAssertFalse(state.showNotes)
        XCTAssertFalse(state.showLedger)
        XCTAssertFalse(state.showLab)
        XCTAssertFalse(state.showArtifacts)
    }

    @MainActor
    func testWeeklyProgressDashboardRendersAtItsSupportedSize() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("store"))
        let week = WeeklyProgressWeek(containing: Date())
        let project = WeeklyProgressProject(
            name: "VLM gating",
            panels: [
                WeeklyProgressPanelSelector(session: "vlm_gating"),
                WeeklyProgressPanelSelector(session: "eval_router"),
            ],
            workspaceRoots: ["/Users/test/research/vlm"]
        )
        var generation = try store.createGeneration(project: project, week: week)
        generation.manifest.stage = .complete
        generation.manifest.evidence = WeeklyProgressEvidenceSummary(
            eventCount: 184,
            byteCount: 9_000,
            sourceFiles: ["journal.jsonl"],
            kinds: ["utterance": 62],
            sessions: ["vlm_gating": 120],
            machines: ["babel-p9-16": 184],
            folders: ["/Users/test/research/vlm"]
        )
        generation.manifest.outputs["languageAudit"] = "language-audit.json"
        try store.write(generation.manifest, in: generation.directory)
        try makeTestPowerPoint(
            at: generation.directory.appendingPathComponent("weekly-progress.pptx"),
            slideCount: 8
        )
        let render = generation.directory.appendingPathComponent("render/final", isDirectory: true)
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        for index in 1...8 {
            try Data("png".utf8).write(to: render.appendingPathComponent("slide-\(index).png"))
        }

        let controller = WeeklyProgressController(store: store)
        controller.selectProject(project.id)
        controller.selectWeek(week)
        let host = NSHostingView(rootView: WeeklyProgressView()
            .environmentObject(AppState(isolatedForTesting: true))
            .environmentObject(controller))
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 760)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_WEEKLY_PROGRESS_TEST"] {
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path)
            )
        }
    }

    @MainActor
    func testWeeklyProgressAllProjectsGalleryRendersAtItsSupportedSize() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("all-gallery-store"))
        let week = WeeklyProgressWeek(containing: Date())
        for (name, session, slideCount) in [
            ("Spatial Bench", "spatial_fable", 4),
            ("Token-Efficient CUAs", "vlm_gating", 3),
        ] {
            let project = WeeklyProgressProject(
                name: name,
                panels: [WeeklyProgressPanelSelector(session: session)]
            )
            var generation = try store.createGeneration(project: project, week: week)
            generation.manifest.stage = .complete
            try store.write(generation.manifest, in: generation.directory)
            let render = generation.directory.appendingPathComponent("render/final", isDirectory: true)
            try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
            for index in 1...slideCount {
                try makeSampleSlide(
                    at: render.appendingPathComponent("slide-\(index).png"),
                    title: "\(name) research result \(index)"
                )
            }
        }

        let controller = WeeklyProgressController(store: store)
        controller.selectAllProjects()
        controller.selectWeek(week)
        let calendarCapture = ProcessInfo.processInfo.environment["UT_CAPTURE_WEEKLY_PROGRESS_CALENDAR"]
        let host = NSHostingView(rootView: WeeklyProgressView(
            initialBrowseMode: calendarCapture == nil ? .selectedWeek : .calendarList
        )
            .environmentObject(AppState(isolatedForTesting: true))
            .environmentObject(controller))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = calendarCapture
            ?? ProcessInfo.processInfo.environment["UT_CAPTURE_WEEKLY_PROGRESS_ALL"] {
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path)
            )
        }
    }

    @MainActor
    func testWeeklyProgressProjectEditorRendersAtItsSupportedSize() throws {
        let state = AppState(isolatedForTesting: true)
        state.machines = [
            Machine(id: "local", name: "this mac", isLocal: true, httpBase: "", wsBase: ""),
            Machine(id: "babel", name: "babel-p9-16", isLocal: false, httpBase: "", wsBase: ""),
        ]
        state.sessionsByMachine = [
            "local": [SessionInfo(name: "vlm_gating", path: "/Users/test/vlm")],
            "babel": [
                SessionInfo(name: "vlm_gating", path: "/compute/babel/test/vlm"),
                SessionInfo(name: "eval_router", path: "/compute/babel/test/vlm"),
            ],
        ]
        state.historyItems = [
            SessionHistoryItem(
                name: "completed_ablation",
                node: "babel-p9-16",
                folders: [FolderSpan(
                    path: "/compute/babel/test/completed-ablation",
                    first: 100,
                    last: Int64(Date().timeIntervalSince1970) - 86_400
                )],
                first: 100,
                last: Int64(Date().timeIntervalSince1970) - 86_400
            ),
        ]
        let project = WeeklyProgressProject(
            name: "VLM gating",
            panels: [WeeklyProgressPanelSelector(session: "vlm_gating")],
            workspaceRoots: ["/Users/test/vlm"]
        )
        let host = NSHostingView(rootView: WeeklyProgressProjectEditor(project: project) { _ in }
            .environmentObject(state))
        host.frame = NSRect(x: 0, y: 0, width: 690, height: 670)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_WEEKLY_PROGRESS_EDITOR"] {
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path)
            )
        }
    }

    @MainActor
    func testWeeklyProgressSlideReaderRendersAtItsSupportedSize() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("reader-store"))
        let project = WeeklyProgressProject(
            name: "Spatial reasoning",
            panels: [WeeklyProgressPanelSelector(session: "spatial_fable")]
        )
        var generation = try store.createGeneration(
            project: project,
            week: WeeklyProgressWeek(containing: Date())
        )
        generation.manifest.stage = .complete
        try store.write(generation.manifest, in: generation.directory)
        let render = generation.directory.appendingPathComponent("render/final", isDirectory: true)
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        try makeSampleSlide(
            at: render.appendingPathComponent("slide-1.png"),
            title: "The corrected router improves grounded action selection"
        )
        try makeSampleSlide(
            at: render.appendingPathComponent("slide-2.png"),
            title: "The gain remains after matched-request evaluation"
        )
        try "# Weekly research report\n\nThe corrected evaluation changes the result.".write(
            to: generation.directory.appendingPathComponent("research-report.md"),
            atomically: true,
            encoding: .utf8
        )

        let host = NSHostingView(rootView: WeeklyProgressReaderView(generation: generation) {})
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 760)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_WEEKLY_PROGRESS_READER"] {
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path)
            )
        }
    }

    func testProjectMembershipSpansPanelsMachinesAndRemotePathSyntax() {
        let project = WeeklyProgressProject(
            name: "VLM gating",
            panels: [
                WeeklyProgressPanelSelector(session: "vlm_gating"),
                WeeklyProgressPanelSelector(session: "eval", machineID: "pranjala-win"),
            ],
            workspaceRoots: ["D:\\research\\vlm"]
        )

        XCTAssertTrue(WeeklyProgressEvidenceFilter.includes(
            ["session": "vlm_gating", "machineID": "babel-p9-16"],
            project: project
        ))
        XCTAssertTrue(WeeklyProgressEvidenceFilter.includes(
            ["session": "eval", "machineID": "pranjala-win"],
            project: project
        ))
        XCTAssertFalse(WeeklyProgressEvidenceFilter.includes(
            ["session": "eval", "machineID": "another-machine"],
            project: project
        ))
        XCTAssertTrue(WeeklyProgressEvidenceFilter.includes(
            ["folder": "d:/research/vlm/results/run-1"],
            project: project
        ))
        XCTAssertFalse(WeeklyProgressEvidenceFilter.includes(
            ["folder": "D:\\research\\vlm-old"],
            project: project
        ))
        XCTAssertTrue(WeeklyProgressEvidenceFilter.includes(
            ["project": "vlm GATING"],
            project: project
        ))
    }

    func testEvidenceCollectorWritesOnlyTheRequestedProjectAndWeek() throws {
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["ts": "2026-08-03T10:00:00Z", "kind": "utterance", "session": "lsd", "machine": "mac"],
            ["ts": "2026-08-04T10:00:00Z", "kind": "outcome", "session": "helper", "folder": "/work/lsd/runs"],
            ["ts": "2026-08-05T10:00:00Z", "kind": "planner", "project": "LSD"],
            ["ts": "2026-08-06T10:00:00Z", "kind": "utterance", "session": "unrelated"],
            ["ts": "2026-08-10T00:00:00Z", "kind": "utterance", "session": "lsd"],
        ]
        var bytes = Data()
        for row in rows {
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(0x0a)
        }
        try bytes.write(to: journal.appendingPathComponent("2026-08-03.jsonl"))
        try Data().write(to: journal.appendingPathComponent("2026-08-04.jsonl"))
        try Data().write(to: journal.appendingPathComponent("2026-08-05.jsonl"))
        try Data().write(to: journal.appendingPathComponent("2026-08-06.jsonl"))
        try Data().write(to: journal.appendingPathComponent("2026-08-07.jsonl"))
        try Data().write(to: journal.appendingPathComponent("2026-08-08.jsonl"))
        try Data().write(to: journal.appendingPathComponent("2026-08-09.jsonl"))

        let summary = try WeeklyProgressEvidenceCollector(
            journalDirectory: journal,
            calendar: calendar
        ).collect(
            project: WeeklyProgressProject(
                name: "lsd",
                panels: [WeeklyProgressPanelSelector(session: "lsd")],
                workspaceRoots: ["/work/lsd"]
            ),
            week: WeeklyProgressWeek(start: date(day: 3), calendar: calendar),
            into: evidence
        )

        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.kinds, ["utterance": 1, "outcome": 1, "planner": 1])
        XCTAssertEqual(summary.sourceFiles, ["2026-08-03.jsonl"])
        let output = try String(
            contentsOf: evidence.appendingPathComponent("journal.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(output.contains("\"session\":\"lsd\""))
        XCTAssertTrue(output.contains("\"project\":\"LSD\""))
        XCTAssertFalse(output.contains("unrelated"))
        XCTAssertFalse(output.contains("2026-08-10"))
    }

    func testCodexCommandPinsSolXHighAndKeepsConversationDurable() {
        let initial = CodexWeeklyProgressCommand.initialArguments(
            directory: URL(fileURLWithPath: "/tmp/progress"),
            finalMessageURL: URL(fileURLWithPath: "/tmp/final.txt")
        )
        let resumed = CodexWeeklyProgressCommand.resumeArguments(
            sessionID: "019f630d-5663-7722-bc65-5fd298a497ec",
            finalMessageURL: URL(fileURLWithPath: "/tmp/audit.txt")
        )

        XCTAssertTrue(initial.contains("gpt-5.6-sol"))
        XCTAssertTrue(initial.contains("model_reasoning_effort=\"xhigh\""))
        XCTAssertTrue(initial.contains("workspace-write"))
        XCTAssertFalse(initial.contains("--ephemeral"))
        XCTAssertEqual(Array(resumed.prefix(2)), ["exec", "resume"])
        XCTAssertTrue(resumed.contains("019f630d-5663-7722-bc65-5fd298a497ec"))
        XCTAssertTrue(resumed.contains("gpt-5.6-sol"))
    }

    func testProjectCatalogAndSameWeekVersionsRemainDistinct() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("store"))
        let project = WeeklyProgressProject(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Spatial sound",
            panels: [WeeklyProgressPanelSelector(session: "spatial_sound")],
            workspaceRoots: ["/work/spatial"],
            createdAt: date(day: 3),
            updatedAt: date(day: 3)
        )
        try store.saveProject(project)
        let week = WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        let first = try store.createGeneration(
            project: project,
            week: week,
            now: date(day: 4, hour: 10),
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = try store.createGeneration(
            project: project,
            week: week,
            now: date(day: 4, hour: 11),
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertEqual(store.loadProjects(), [project])
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(store.generations(projectID: project.id).count, 2)
        XCTAssertEqual(first.manifest.promptRevision, WeeklyProgressPrompts.revision)
    }

    @MainActor
    func testAllProjectsSelectionAggregatesEveryProjectWithoutCreatingSyntheticData() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("all-store"))
        let week = WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        let projectA = WeeklyProgressProject(
            name: "Alpha research",
            panels: [WeeklyProgressPanelSelector(session: "alpha")]
        )
        let projectB = WeeklyProgressProject(
            name: "Beta research",
            panels: [WeeklyProgressPanelSelector(session: "beta")]
        )
        _ = try store.createGeneration(project: projectA, week: week, now: date(day: 4, hour: 9))
        _ = try store.createGeneration(project: projectB, week: week, now: date(day: 4, hour: 10))

        let controller = WeeklyProgressController(store: store, now: date(day: 5))
        controller.selectAllProjects()

        XCTAssertNil(controller.selectedProject)
        XCTAssertEqual(controller.generations.count, 2)
        XCTAssertEqual(Set(controller.generations.map { $0.manifest.project.id }), [projectA.id, projectB.id])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.rootURL.appendingPathComponent("projects/all").path
        ))
    }

    func testCollectionCatalogUsesLatestStateAndLatestReadableDeckPerProject() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("catalog-store"))
        let week = WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        let projectA = WeeklyProgressProject(
            name: "Alpha research",
            panels: [WeeklyProgressPanelSelector(session: "alpha")]
        )
        let projectB = WeeklyProgressProject(
            name: "Beta research",
            panels: [WeeklyProgressPanelSelector(session: "beta")]
        )
        var completedA = try store.createGeneration(
            project: projectA,
            week: week,
            now: date(day: 4, hour: 9)
        )
        completedA.manifest.stage = .complete
        try store.write(completedA.manifest, in: completedA.directory)
        let activeA = try store.createGeneration(
            project: projectA,
            week: week,
            now: date(day: 4, hour: 11)
        )
        var completedB = try store.createGeneration(
            project: projectB,
            week: week,
            now: date(day: 4, hour: 10)
        )
        completedB.manifest.stage = .complete
        try store.write(completedB.manifest, in: completedB.directory)

        let all = store.allGenerations()
        let entries = WeeklyProgressGenerationCatalog.entries(for: week, in: all)

        XCTAssertEqual(entries.map { $0.latest.manifest.project.name }, [
            "Alpha research", "Beta research",
        ])
        XCTAssertEqual(entries[0].latest.manifest.id, activeA.manifest.id)
        XCTAssertEqual(entries[0].latestComplete?.manifest.id, completedA.manifest.id)
        XCTAssertEqual(entries[0].versionCount, 2)
        XCTAssertEqual(entries[1].latestComplete?.manifest.id, completedB.manifest.id)
        XCTAssertEqual(WeeklyProgressGenerationCatalog.calendarSections(in: all).count, 1)
    }

    func testSlideCatalogIncludesOnlyNumberedSlidesInNumericOrder() throws {
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("slide-catalog-store"))
        let project = WeeklyProgressProject(
            name: "Slides",
            panels: [WeeklyProgressPanelSelector(session: "slides")]
        )
        let generation = try store.createGeneration(
            project: project,
            week: WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        )
        let render = generation.directory.appendingPathComponent("render/final", isDirectory: true)
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        for name in ["slide-10.png", "slide-2.png", "slide-1.png", "montage.png", "slide-x.png"] {
            try Data("png".utf8).write(to: render.appendingPathComponent(name))
        }

        XCTAssertEqual(
            WeeklyProgressSlideCatalog.urls(for: generation).map(\.lastPathComponent),
            ["slide-1.png", "slide-2.png", "slide-10.png"]
        )
    }

    func testCodexSessionIDParsesFromJSONEventStream() {
        let stream = #"{"type":"thread.started","thread_id":"019f630d-5663-7722-bc65-5fd298a497ec"}"#
            + "\n" + #"{"type":"turn.started"}"#
        XCTAssertEqual(
            CodexWeeklyProgressCommand.sessionID(in: stream),
            "019f630d-5663-7722-bc65-5fd298a497ec"
        )
    }

    func testHeadlessHarnessParsesOnlyExplicitGenerateAndResumeCommands() {
        XCTAssertEqual(
            WeeklyProgressCommandLine.operation(arguments: [
                "Argus", "--weekly-progress-generate", "/tmp/request.json",
            ]),
            .generate(URL(fileURLWithPath: "/tmp/request.json"))
        )
        XCTAssertEqual(
            WeeklyProgressCommandLine.operation(arguments: [
                "Argus", "--weekly-progress-resume", "/tmp/generation",
            ]),
            .resume(URL(fileURLWithPath: "/tmp/generation"))
        )
        XCTAssertNil(WeeklyProgressCommandLine.operation(arguments: ["Argus", "--other", "/tmp/x"]))
        XCTAssertNil(WeeklyProgressCommandLine.operation(arguments: ["Argus"]))
    }

    func testPromptsReplayTheExactSuccessfulReferenceSessionInstructions() {
        let project = WeeklyProgressProject(
            name: "LSD",
            panels: [WeeklyProgressPanelSelector(session: "lsd")]
        )
        let week = WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        let research = WeeklyProgressPrompts.reconstructResearch(project: project, week: week)
        let slides = WeeklyProgressPrompts.draftSlides(project: project, week: week)
        let firstCorrection = WeeklyProgressPrompts.referenceCorrection(pass: 1)
        let secondCorrection = WeeklyProgressPrompts.referenceCorrection(pass: 2)
        let thirdCorrection = WeeklyProgressPrompts.referenceCorrection(pass: 3)

        XCTAssertEqual(
            sha256(WeeklyProgressPrompts.researchInstruction),
            "6c78705e7d780d39fddf39fd0f2ffead9185d171cf34f3cc1e3de6002be56d3d"
        )
        XCTAssertEqual(
            sha256(WeeklyProgressPrompts.slideInstruction),
            "229d5eca6b577fa1e987e807e75e2155e091a1864572df545cde79fe0a1252b2"
        )
        XCTAssertEqual(
            sha256(WeeklyProgressPrompts.readabilityCorrectionInstruction),
            "44244854b85cbb48af480cca01726e9fe14b241e2336e72c19c0df27ba87867e"
        )
        XCTAssertEqual(
            sha256(WeeklyProgressPrompts.fontCorrectionInstruction),
            "cc79ebc6d591859af30dcc826e9a9a90c1ef5239088ac9efaf6698d684f54d15"
        )
        XCTAssertEqual(
            sha256(WeeklyProgressPrompts.languageCorrectionInstruction),
            "b16cea0e433ca4654c2a9d6af1fb59d4b249a737315d979c3501c677ebf73960"
        )

        XCTAssertTrue(research.contains(WeeklyProgressPrompts.researchInstruction))
        XCTAssertTrue(slides.contains(WeeklyProgressPrompts.slideInstruction))
        XCTAssertTrue(slides.contains("draft.pptx"))
        XCTAssertFalse(research.contains("Failed gates"))
        XCTAssertFalse(research.contains("objective failures"))
        XCTAssertTrue(firstCorrection.contains(WeeklyProgressPrompts.readabilityCorrectionInstruction))
        XCTAssertFalse(firstCorrection.contains(WeeklyProgressPrompts.fontCorrectionInstruction))
        XCTAssertTrue(secondCorrection.contains(WeeklyProgressPrompts.readabilityCorrectionInstruction))
        XCTAssertTrue(secondCorrection.contains(WeeklyProgressPrompts.fontCorrectionInstruction))
        XCTAssertFalse(secondCorrection.contains(WeeklyProgressPrompts.languageCorrectionInstruction))
        XCTAssertTrue(thirdCorrection.contains(WeeklyProgressPrompts.readabilityCorrectionInstruction))
        XCTAssertTrue(thirdCorrection.contains(WeeklyProgressPrompts.fontCorrectionInstruction))
        XCTAssertTrue(thirdCorrection.contains(WeeklyProgressPrompts.languageCorrectionInstruction))
        XCTAssertTrue(thirdCorrection.contains("weekly-progress.pptx"))
        XCTAssertTrue(thirdCorrection.contains("audit.json"))
        XCTAssertEqual(WeeklyProgressPrompts.requiredReferenceCorrectionCount, 3)
        XCTAssertEqual(WeeklyProgressPrompts.revision, "reference-session-019f630d-v1")
    }

    func testPowerPointGateRequiresAValidDeckAndEveryRenderedSlide() throws {
        let deck = root.appendingPathComponent("two-slides.pptx")
        try makeMinimalDeck(at: deck, slideCount: 2)
        let render = root.appendingPathComponent("render", isDirectory: true)
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: render.appendingPathComponent("slide-1.png"))

        XCTAssertEqual(WeeklyProgressPowerPointInspection.slideCount(at: deck), 2)
        XCTAssertFalse(WeeklyProgressPowerPointInspection.hasCompleteRender(
            deckURL: deck,
            renderDirectory: render
        ))
        try Data("two".utf8).write(to: render.appendingPathComponent("slide-2.png"))
        XCTAssertTrue(WeeklyProgressPowerPointInspection.hasCompleteRender(
            deckURL: deck,
            renderDirectory: render
        ))
    }

    func testPowerPointLanguageGateReadsTextAndRejectsObjectiveViolations() throws {
        let deck = root.appendingPathComponent("language-failures.pptx")
        try makeTestPowerPoint(at: deck, texts: [
            "The result: trajectory improved—but this is not merely noise.",
        ])

        let runs = try XCTUnwrap(WeeklyProgressPowerPointInspection.visibleTextRuns(at: deck))
        XCTAssertEqual(runs.map(\.text), [
            "The result: trajectory improved—but this is not merely noise.",
        ])
        let audit = WeeklyProgressLanguageInspection.audit(deckURL: deck)

        XCTAssertFalse(audit.passed)
        XCTAssertEqual(audit.textRunCount, 1)
        let rules = Set(audit.issues.map(\.rule))
        XCTAssertTrue(rules.contains("Colon"))
        XCTAssertTrue(rules.contains("Em dash"))
        XCTAssertTrue(rules.contains("Rhetorical contrast formula"))
        XCTAssertTrue(rules.contains("Unexplained compressed term: trajectory"))
    }

    func testPowerPointLanguageGateAllowsAnEssentialTermAfterDefinition() throws {
        let deck = root.appendingPathComponent("defined-term.pptx")
        try makeTestPowerPoint(at: deck, texts: [
            "Trajectory means the measured path through parameter space.",
            "The measured trajectory changed after the intervention.",
        ])

        let audit = WeeklyProgressLanguageInspection.audit(deckURL: deck)

        XCTAssertTrue(audit.passed, audit.issues.map(\.rule).joined(separator: ", "))
        XCTAssertEqual(audit.textRunCount, 2)
        XCTAssertTrue(audit.issues.isEmpty)
    }

    func testPowerPointLanguageGateIncludesVisibleChartCategories() throws {
        let deck = root.appendingPathComponent("chart-language.pptx")
        try makeTestPowerPoint(
            at: deck,
            texts: ["The chart reports the measured comparison."],
            chartTexts: ["No--router Stage A"]
        )

        let runs = try XCTUnwrap(WeeklyProgressPowerPointInspection.visibleTextRuns(at: deck))
        XCTAssertTrue(runs.contains { $0.text == "No--router Stage A" })
        let audit = WeeklyProgressLanguageInspection.audit(deckURL: deck)
        XCTAssertTrue(audit.issues.contains { $0.rule == "Double hyphen" })
    }

    func testPipelineRejectsModelPassingAuditWithLanguageViolations() async throws {
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let event = #"{"kind":"utterance","machine":"mac","session":"lsd","ts":"2026-08-03T10:00:00Z"}"#
        try (event + "\n").write(
            to: journal.appendingPathComponent("2026-08-03.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        for day in 4...9 {
            try Data().write(to: journal.appendingPathComponent(String(format: "2026-08-%02d.jsonl", day)))
        }
        let fake = FakeWeeklyProgressAgent()
        let pipeline = WeeklyProgressPipeline(
            store: WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("store")),
            journalDirectory: journal,
            agent: fake,
            maximumAuditPasses: 3
        )

        let generation = try await pipeline.generate(
            project: WeeklyProgressProject(
                name: "LSD",
                panels: [WeeklyProgressPanelSelector(session: "lsd")]
            ),
            week: WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        )

        XCTAssertEqual(generation.manifest.stage, .complete)
        XCTAssertEqual(generation.manifest.auditPasses, 3)
        XCTAssertEqual(generation.manifest.codexSessionID, FakeWeeklyProgressAgent.sessionID)
        let resumeCount = await fake.resumeCount()
        XCTAssertEqual(resumeCount, 4)
        let prompts = await fake.resumePrompts()
        XCTAssertEqual(prompts.count, 4)
        XCTAssertTrue(prompts[1].contains(WeeklyProgressPrompts.readabilityCorrectionInstruction))
        XCTAssertFalse(prompts[1].contains(WeeklyProgressPrompts.fontCorrectionInstruction))
        XCTAssertTrue(prompts[2].contains(WeeklyProgressPrompts.fontCorrectionInstruction))
        XCTAssertFalse(prompts[2].contains(WeeklyProgressPrompts.languageCorrectionInstruction))
        XCTAssertTrue(prompts[3].contains(WeeklyProgressPrompts.languageCorrectionInstruction))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: generation.directory.appendingPathComponent("weekly-progress.pptx").path
        ))
        let languageAudit = try WeeklyProgressJSON.read(
            WeeklyProgressLanguageAudit.self,
            from: generation.directory.appendingPathComponent("language-audit.json")
        )
        XCTAssertTrue(languageAudit.passed)
        let stored = try WeeklyProgressDiskStore(
            rootURL: root.appendingPathComponent("store")
        ).load(from: generation.directory)
        XCTAssertEqual(stored.stage, .complete)
        XCTAssertEqual(stored.outputs["finalDeck"], "weekly-progress.pptx")
    }

    func testInterruptedGenerationResumesFromDurableStageAndCodexSession() async throws {
        let journal = root.appendingPathComponent("resume-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try #"{"kind":"utterance","session":"lsd","ts":"2026-08-03T10:00:00Z"}"#.appending("\n").write(
            to: journal.appendingPathComponent("2026-08-03.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        for day in 4...9 {
            try Data().write(to: journal.appendingPathComponent(String(format: "2026-08-%02d.jsonl", day)))
        }
        let fake = FakeWeeklyProgressAgent(safeAfterResumeCount: 6)
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("resume-store"))
        let pipeline = WeeklyProgressPipeline(
            store: store,
            journalDirectory: journal,
            agent: fake,
            maximumAuditPasses: 1
        )
        let project = WeeklyProgressProject(
            name: "LSD",
            panels: [WeeklyProgressPanelSelector(session: "lsd")]
        )
        do {
            _ = try await pipeline.generate(
                project: project,
                week: WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
            )
            XCTFail("The deliberately incomplete first audit should not complete")
        } catch {
            XCTAssertTrue(error is WeeklyProgressPipelineError)
        }

        let failed = try XCTUnwrap(store.generations(projectID: project.id).first)
        XCTAssertEqual(failed.manifest.stage, .failed)
        XCTAssertEqual(failed.manifest.auditPasses, 4)
        XCTAssertEqual(failed.manifest.codexSessionID, FakeWeeklyProgressAgent.sessionID)

        let resumed = try await pipeline.resume(generationDirectory: failed.directory)

        XCTAssertEqual(resumed.manifest.stage, .complete)
        XCTAssertEqual(resumed.manifest.auditPasses, 5)
        let startCount = await fake.startCount()
        let resumeCount = await fake.resumeCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resumeCount, 6)
    }

    func testInterruptedLegacyGenerationCannotMixPromptContractsOnResume() async throws {
        let journal = root.appendingPathComponent("legacy-resume-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("legacy-resume-store"))
        let project = WeeklyProgressProject(
            name: "LSD",
            panels: [WeeklyProgressPanelSelector(session: "lsd")]
        )
        var generation = try store.createGeneration(
            project: project,
            week: WeeklyProgressWeek(start: date(day: 3), calendar: calendar)
        )
        generation.manifest.promptRevision = nil
        generation.manifest.stage = .failed
        try store.write(generation.manifest, in: generation.directory)
        let fake = FakeWeeklyProgressAgent()
        let pipeline = WeeklyProgressPipeline(
            store: store,
            journalDirectory: journal,
            agent: fake
        )

        do {
            _ = try await pipeline.resume(generationDirectory: generation.directory)
            XCTFail("A legacy generation must start a fresh version instead of mixing prompt contracts")
        } catch let error as WeeklyProgressPipelineError {
            guard case .obsoletePromptRevision = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
        }

        let starts = await fake.startCount()
        let resumes = await fake.resumeCount()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(resumes, 0)
    }

    private func date(day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: hour
        ))!
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeMinimalDeck(at url: URL, slideCount: Int) throws {
        try makeTestPowerPoint(at: url, slideCount: slideCount)
    }

    private func makeSampleSlide(at url: URL, title: String) throws {
        let image = NSImage(size: NSSize(width: 1600, height: 900))
        image.lockFocus()
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1600, height: 900)).fill()
        NSColor(calibratedRed: 0.34, green: 0.71, blue: 0.81, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 92, y: 760, width: 155, height: 8)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        (title as NSString).draw(
            in: NSRect(x: 92, y: 560, width: 1340, height: 155),
            withAttributes: attributes
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
    }
}

private actor FakeWeeklyProgressAgent: WeeklyProgressAgentRunning {
    static let sessionID = "019f630d-5663-7722-bc65-5fd298a497ec"
    private let safeAfterResumeCount: Int
    private var starts = 0
    private var resumes = 0
    private var prompts: [String] = []

    init(safeAfterResumeCount: Int = 4) {
        self.safeAfterResumeCount = safeAfterResumeCount
    }

    func start(prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult {
        starts += 1
        try "report".write(
            to: directory.appendingPathComponent("research-report.md"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: directory.appendingPathComponent("evidence-ledger.json"),
            atomically: true,
            encoding: .utf8
        )
        return WeeklyProgressAgentResult(sessionID: Self.sessionID, finalMessage: "research complete")
    }

    func resume(sessionID: String, prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult {
        resumes += 1
        prompts.append(prompt)
        if stageName == "02-draft" {
            try Data("draft".utf8).write(to: directory.appendingPathComponent("draft.pptx"))
        } else if resumes < safeAfterResumeCount {
            // A model assertion is insufficient. The deck and complete render exist,
            // but independent text inspection must reject the language violations.
            try makeTestPowerPoint(
                at: directory.appendingPathComponent("weekly-progress.pptx"),
                texts: ["The result: trajectory improved—but this is not merely noise."]
            )
            let render = directory.appendingPathComponent("render/final", isDirectory: true)
            try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
            try Data("png".utf8).write(to: render.appendingPathComponent("slide-1.png"))
            try #"{"passed":true,"checks":[],"issues":[]}"#.write(
                to: directory.appendingPathComponent("audit.json"),
                atomically: true,
                encoding: .utf8
            )
        } else {
            try makeTestPowerPoint(
                at: directory.appendingPathComponent("weekly-progress.pptx"),
                slideCount: 1
            )
            let render = directory.appendingPathComponent("render/final", isDirectory: true)
            try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
            try Data("png".utf8).write(to: render.appendingPathComponent("slide-1.png"))
            try #"{"passed":true,"checks":[],"issues":[]}"#.write(
                to: directory.appendingPathComponent("audit.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return WeeklyProgressAgentResult(sessionID: sessionID, finalMessage: "complete")
    }

    func resumeCount() -> Int { resumes }
    func startCount() -> Int { starts }
    func resumePrompts() -> [String] { prompts }
}

private func makeTestPowerPoint(at url: URL, slideCount: Int) throws {
    try makeTestPowerPoint(
        at: url,
        texts: (1...slideCount).map { "The measured result on slide \($0) was verified." }
    )
}

private func makeTestPowerPoint(
    at url: URL,
    texts: [String],
    chartTexts: [String] = []
) throws {
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("argus-test-pptx-" + UUID().uuidString, isDirectory: true)
    let slides = source.appendingPathComponent("ppt/slides", isDirectory: true)
    try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: source) }
    try? FileManager.default.removeItem(at: url)
    for (offset, text) in texts.enumerated() {
        let index = offset + 1
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let xml = """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(escaped)</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        try xml.write(
            to: slides.appendingPathComponent("slide\(index).xml"),
            atomically: true,
            encoding: .utf8
        )
    }
    if !chartTexts.isEmpty {
        let charts = source.appendingPathComponent("ppt/charts", isDirectory: true)
        try FileManager.default.createDirectory(at: charts, withIntermediateDirectories: true)
        let points = chartTexts.enumerated().map { index, value in
            let escaped = value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<c:pt idx=\"\(index)\"><c:v>\(escaped)</c:v></c:pt>"
        }.joined()
        let chartXML = """
        <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
          <c:chart><c:plotArea><c:barChart><c:ser><c:cat><c:strRef><c:strCache>
          \(points)
          </c:strCache></c:strRef></c:cat></c:ser></c:barChart></c:plotArea></c:chart>
        </c:chartSpace>
        """
        try chartXML.write(
            to: charts.appendingPathComponent("chart1.xml"),
            atomically: true,
            encoding: .utf8
        )
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-q", "-r", url.path, "ppt"]
    process.currentDirectoryURL = source
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}
