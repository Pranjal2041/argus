import XCTest
@testable import Argus

final class WeeklyProgressTests: XCTestCase {
    // MARK: Catalog decoding

    func testCatalogDecodesCapitalIDKeysNullsAndMissingFields() throws {
        let json = """
        {"version":1,"generatedAt":"2026-10-01T03:42:19Z",
         "projects":[{"id":"p1","name":"Diffusion","panelCount":2,"workspaceCount":1,"updatedAt":"2026-09-30T10:00:00Z"},
                     {"id":"p2","name":"Bare"}],
         "generations":[
           {"id":"g1","projectID":"p1","projectName":"Diffusion","weekStart":"2026-09-28","weekEndExclusive":"2026-10-05",
            "createdAt":"2026-09-30T10:00:00Z","updatedAt":"2026-09-30T11:00:00Z","stage":"complete","state":"complete",
            "auditPasses":2,"slideCount":12,"hasDeck":true,"hasReport":true,"evidenceEventCount":null,"error":null},
           {"id":"g2","projectID":"p1","projectName":"Diffusion","weekStart":"2026-09-28","weekEndExclusive":"2026-10-05",
            "stage":"failed","state":"failed","evidenceEventCount":41,"error":"  "}
         ],
         "activeOperation":{"generationID":"g3","projectID":"p2","projectName":"Bare","weekStart":"2026-09-28",
                            "stage":"draftingSlides","startedAt":"2026-09-30T12:00:00Z"}}
        """
        let c = try WeeklyProgressCatalog.decode(Data(json.utf8))
        XCTAssertEqual(c.projects.map(\.id), ["p1", "p2"])
        XCTAssertEqual(c.projects[1].panelCount, 0)
        XCTAssertEqual(c.projects[0].sourceSummary, "2 panels · 1 folder")
        XCTAssertEqual(c.projects[1].sourceSummary, "Configured on the Mac")

        let g1 = c.generations[0]
        XCTAssertEqual(g1.projectID, "p1")
        XCTAssertEqual(g1.slideCount, 12)
        XCTAssertTrue(g1.hasDeck && g1.hasReport)
        XCTAssertNil(g1.evidenceEventCount)
        XCTAssertNil(g1.error)

        let g2 = c.generations[1]
        XCTAssertEqual(g2.evidenceEventCount, 41)
        XCTAssertNil(g2.error, "a blank error is no error")
        XCTAssertEqual(g2.slideCount, 0)
        XCTAssertFalse(g2.hasDeck)
        XCTAssertEqual(g2.createdAt, "")

        let op = try XCTUnwrap(c.activeOperation)
        XCTAssertEqual(op.generationID, "g3")
        XCTAssertEqual(op.projectID, "p2")
        XCTAssertEqual(WeeklyProgressStage.index(op.stage), 2)
    }

    func testCatalogWithNullOperationAndNoArrays() throws {
        let c = try WeeklyProgressCatalog.decode(Data(#"{"version":1,"activeOperation":null}"#.utf8))
        XCTAssertTrue(c.projects.isEmpty)
        XCTAssertTrue(c.generations.isEmpty)
        XCTAssertNil(c.activeOperation)
        // A generation without its identity fields is malformed, not defaulted.
        XCTAssertThrowsError(try WeeklyProgressCatalog.decode(Data(#"{"generations":[{"id":"g"}]}"#.utf8)))
    }

    // MARK: Weeks

    func testMondayIsComputedInTheGivenTimeZone() throws {
        // 2026-10-05T03:00:00Z is Sunday evening in Los Angeles but Monday in Tokyo.
        let instant = try XCTUnwrap(WeeklyProgressTime.parse("2026-10-05T03:00:00Z"))
        let la = WeeklyProgressWeek.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        let tokyo = WeeklyProgressWeek.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        XCTAssertEqual(WeeklyProgressWeek.currentKey(now: instant, calendar: la), "2026-09-28")
        XCTAssertEqual(WeeklyProgressWeek.currentKey(now: instant, calendar: tokyo), "2026-10-05")

        // Every day of a week maps to its Monday.
        for day in 28...30 {
            let d = try XCTUnwrap(WeeklyProgressWeek.date(fromKey: "2026-09-\(day)", calendar: la))
            XCTAssertEqual(WeeklyProgressWeek.key(for: WeeklyProgressWeek.monday(containing: d, calendar: la), calendar: la), "2026-09-28")
        }
        let sunday = try XCTUnwrap(WeeklyProgressWeek.date(fromKey: "2026-10-04", calendar: la))
        XCTAssertEqual(WeeklyProgressWeek.key(for: WeeklyProgressWeek.monday(containing: sunday, calendar: la), calendar: la), "2026-09-28")
    }

    func testWeekShiftCrossesDSTAndYearBoundaries() throws {
        let la = WeeklyProgressWeek.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        XCTAssertEqual(WeeklyProgressWeek.shift("2026-03-02", by: 1, calendar: la), "2026-03-09")   // DST starts Mar 8
        XCTAssertEqual(WeeklyProgressWeek.shift("2026-11-02", by: -1, calendar: la), "2026-10-26")  // DST ends Nov 1
        XCTAssertEqual(WeeklyProgressWeek.shift("2026-12-28", by: 1, calendar: la), "2027-01-04")
        XCTAssertEqual(WeeklyProgressWeek.shift("2026-10-01", by: 0, calendar: la), "2026-09-28", "a mid-week key snaps to Monday")
        let title = WeeklyProgressWeek.rangeTitle("2026-09-28", calendar: la, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(title.contains("Sep 28") && title.contains("Oct 4"), title)
    }

    // MARK: Shelves

    private func gen(_ id: String, project: String, name: String? = nil, week: String = "2026-09-28",
                     created: String, state: String = "complete", slides: Int = 5) -> WeeklyProgressGeneration {
        let json = """
        {"id":"\(id)","projectID":"\(project)","projectName":"\(name ?? project)","weekStart":"\(week)",
         "weekEndExclusive":"x","createdAt":"\(created)","updatedAt":"\(created)","stage":"complete",
         "state":"\(state)","slideCount":\(slides)}
        """
        return try! JSONDecoder().decode(WeeklyProgressGeneration.self, from: Data(json.utf8))
    }

    func testAllProjectsShowsNewestPerProjectButKeepsAReadableEditionDuringAReplacement() {
        let gens = [
            gen("a1", project: "a", name: "beta", created: "2026-09-29T09:00:00Z"),
            gen("a2", project: "a", name: "beta", created: "2026-09-30T09:00:00Z"),
            gen("a3", project: "a", name: "beta", created: "2026-09-30T12:00:00Z", state: "active", slides: 0),
            gen("b1", project: "b", name: "Alpha", created: "2026-09-29T09:00:00Z", state: "active", slides: 0),
            gen("c1", project: "c", name: "gamma", created: "2026-09-30T09:00:00Z", state: "failed", slides: 0),
            gen("c2", project: "c", name: "gamma", week: "2026-09-21", created: "2026-09-22T09:00:00Z"),
        ]
        let shelf = WeeklyProgressShelf.allProjects(gens, week: "2026-09-28")
        // a: newest is an in-flight replacement without slides → previous readable edition.
        // b: only an in-flight run → shown as is. c: newest (failed) wins; other weeks are ignored.
        XCTAssertEqual(shelf.map(\.id), ["b1", "a2", "c1"], "sorted by project name, case-insensitively")

        // Once the replacement has slides, it takes over.
        let withSlides = gens.filter { $0.id != "a3" } + [gen("a3", project: "a", name: "beta", created: "2026-09-30T12:00:00Z", state: "active", slides: 3)]
        XCTAssertEqual(WeeklyProgressShelf.allProjects(withSlides, week: "2026-09-28").first { $0.projectID == "a" }?.id, "a3")
    }

    func testProjectShelfAndCalendarAreNewestFirst() {
        let gens = [
            gen("1", project: "p", week: "2026-09-21", created: "2026-09-22T09:00:00Z"),
            gen("2", project: "p", created: "2026-09-29T09:00:00Z"),
            gen("3", project: "p", created: "2026-09-30T09:00:00Z"),
            gen("x", project: "q", created: "2026-09-30T10:00:00Z"),
        ]
        XCTAssertEqual(WeeklyProgressShelf.project(gens, projectID: "p", week: "2026-09-28").map(\.id), ["3", "2"])
        let sections = WeeklyProgressShelf.calendar(gens, projectID: "p")
        XCTAssertEqual(sections.map(\.week), ["2026-09-28", "2026-09-21"])
        XCTAssertEqual(sections[0].versions.map(\.id), ["3", "2"])
        XCTAssertEqual(WeeklyProgressShelf.versionLabel(1), "1 version")
        XCTAssertEqual(WeeklyProgressShelf.versionLabel(2), "2 versions")
    }

    func testCanResumeOnlyInterruptedOrFailed() {
        XCTAssertTrue(gen("1", project: "p", created: "", state: "interrupted").canResume)
        XCTAssertTrue(gen("2", project: "p", created: "", state: "failed").canResume)
        XCTAssertFalse(gen("3", project: "p", created: "", state: "active").canResume)
        XCTAssertFalse(gen("4", project: "p", created: "", state: "complete").canResume)
    }

    // MARK: Commands

    func testRequestIDRetentionRules() {
        XCTAssertTrue(WeeklyProgressRequestIDs.shouldKeep(status: nil), "transport failure: the Mac may have accepted")
        XCTAssertTrue(WeeklyProgressRequestIDs.shouldKeep(status: 500))
        XCTAssertTrue(WeeklyProgressRequestIDs.shouldKeep(status: 503))
        XCTAssertTrue(WeeklyProgressRequestIDs.shouldKeep(status: 409))
        XCTAssertFalse(WeeklyProgressRequestIDs.shouldKeep(status: 202))
        XCTAssertFalse(WeeklyProgressRequestIDs.shouldKeep(status: 400))
        XCTAssertFalse(WeeklyProgressRequestIDs.shouldKeep(status: 404))
    }

    func testRequestIDsPersistPerActionUntilSettled() throws {
        let suite = "WeeklyProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = WeeklyProgressRequestIDs(defaults: defaults)
        let generate = WeeklyProgressRequestIDs.Action.generate(projectID: "p", week: "2026-09-28")
        let otherWeek = WeeklyProgressRequestIDs.Action.generate(projectID: "p", week: "2026-09-21")
        let resume = WeeklyProgressRequestIDs.Action.resume(generationID: "g")

        let first = ids.id(for: generate)
        XCTAssertTrue(first.hasPrefix("ios-") && !first.hasPrefix("ios-resume-"))
        XCTAssertTrue(ids.id(for: resume).hasPrefix("ios-resume-"))
        XCTAssertNotEqual(ids.id(for: otherWeek), first)

        ids.settle(generate, status: nil)
        XCTAssertEqual(ids.id(for: generate), first, "retry after a transport failure reuses the id")
        ids.settle(generate, status: 503)
        XCTAssertEqual(WeeklyProgressRequestIDs(defaults: defaults).id(for: generate), first, "persisted, not in memory")
        ids.settle(generate, status: 202)
        let second = ids.id(for: generate)
        XCTAssertNotEqual(second, first, "a new id after success")
        ids.settle(generate, status: 400)
        XCTAssertNotEqual(ids.id(for: generate), second, "a new id after a definitive rejection")
    }

    func testCommandFailureMessages() {
        XCTAssertEqual(WeeklyProgressMessages.commandFailure(resume: false, status: 503, serverError: "provider is not running"),
                       "Open Argus on your Mac before starting a review.")
        XCTAssertEqual(WeeklyProgressMessages.commandFailure(resume: false, status: 409, serverError: nil),
                       "Another Weekly Progress review is already running on the Mac.")
        XCTAssertEqual(WeeklyProgressMessages.commandFailure(resume: false, status: 409, serverError: "A review for X is already running."),
                       "A review for X is already running.")
        XCTAssertEqual(WeeklyProgressMessages.commandFailure(resume: false, status: 400, serverError: ""),
                       "The Mac could not start this review.")
        XCTAssertEqual(WeeklyProgressMessages.commandFailure(resume: true, status: 500, serverError: nil),
                       "The Mac could not resume this review.")
        XCTAssertTrue(WeeklyProgressMessages.commandFailure(resume: true, status: nil, serverError: "timed out").contains("could not be reached"))
    }

    // MARK: Files

    func testDeckFilenameIsSanitizedLikeTheMac() {
        XCTAssertEqual(WeeklyProgressFiles.deckFilename(projectName: "Diffusion: v2 / ablations", weekStart: "2026-09-28"),
                       "Diffusion-v2-ablations-week-of-2026-09-28.pptx")
        XCTAssertEqual(WeeklyProgressFiles.deckFilename(projectName: "--already_safe.name--", weekStart: "2026-09-28"),
                       "already_safe.name-week-of-2026-09-28.pptx")
        XCTAssertEqual(WeeklyProgressFiles.deckFilename(projectName: "研究", weekStart: "2026-09-28"),
                       "weekly-progress-week-of-2026-09-28.pptx")
    }

    func testCachePathsCannotEscapeAndPruneEvictsOldThenLargest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeeklyProgressCache(cacheRoot: root.appendingPathComponent("cache"), catalogFile: root.appendingPathComponent("c.json"))
        XCTAssertEqual(WeeklyProgressCache.component("../../etc"), ".._.._etc")
        XCTAssertEqual(WeeklyProgressCache.component(".."), "_")
        XCTAssertTrue(cache.reportFile("../x").path.hasPrefix(cache.cacheRoot.path))

        let g = gen("g", project: "p", created: "2026-09-30T09:00:00Z")
        let now = Date()
        let old = cache.slideFile(g, 1), lru = cache.slideFile(g, 2), fresh = cache.slideFile(g, 3)
        for f in [old, lru, fresh] { cache.write(Data(count: 100), to: f) }
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86400)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: lru.path)
        cache.prune(now: now, maxBytes: 150)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "older than the age limit")
        XCTAssertFalse(fm.fileExists(atPath: lru.path), "least recently used goes first when over size")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))

        // A new revision of the same generation replaces the old renders.
        cache.write(Data(count: 10), to: cache.slideFile(gen("g", project: "p", created: "2026-10-01T09:00:00Z"), 1),
                    replacingSiblingRevisions: true)
        XCTAssertFalse(fm.fileExists(atPath: fresh.path))
    }

    // MARK: Markdown

    func testMarkdownBlocks() {
        let md = """
        # Weekly review ##
        Intro line one
        continues here.

        - first
          wrapped
        * second
        1. one
        2) two
        > quoted
        > more
        ---
        | Run | Loss |
        |:----|-----:|
        | a | 0.1 |
        ```swift
        let x = 1
        # not a heading
        ```
        **bold** paragraph
        """
        XCTAssertEqual(WeeklyProgressMarkdown.blocks(md), [
            .heading(level: 1, text: "Weekly review"),
            .paragraph("Intro line one continues here."),
            .bullet(indent: 0, text: "first wrapped"),
            .bullet(indent: 0, text: "second"),
            .numbered(indent: 0, marker: "1.", text: "one"),
            .numbered(indent: 0, marker: "2.", text: "two"),
            .quote("quoted more"),
            .rule,
            .table([["Run", "Loss"], ["a", "0.1"]]),
            .code("let x = 1\n# not a heading"),
            .paragraph("**bold** paragraph"),
        ])
    }
}
