import Foundation
import XCTest
@testable import UniversalTmuxMac

final class FileArtifactTests: XCTestCase {
    @MainActor
    func testDirtyEditorSnapshotUsesVisibleDraft() {
        let tab = FileTab(machine: machine(), sourcePanel: panel())
        let entry = file(name: "decision.md", size: 12)
        let doc = OpenDoc(
            path: entry.path,
            name: entry.name,
            content: .text("old on disk", name: entry.name, path: entry.path)
        )
        doc.loadedText("old on disk")
        doc.editorChanged("visible unsaved verdict")
        tab.openDocs = [doc]
        tab.activeDocID = doc.id

        let material = tab.artifactMaterial(for: entry)

        XCTAssertEqual(String(data: material!.data, encoding: .utf8), "visible unsaved verdict")
        XCTAssertEqual(material?.presentation, "file-draft")
        XCTAssertEqual(material?.contentType, "text/markdown")
    }

    @MainActor
    func testCleanPreviewSnapshotUsesLoadedVersion() {
        let tab = FileTab(machine: machine(), sourcePanel: panel())
        let entry = file(name: "result.json", size: 30)
        let doc = OpenDoc(
            path: entry.path,
            name: entry.name,
            content: .text("loaded result", name: entry.name, path: entry.path)
        )
        doc.loadedText("loaded result")
        tab.openDocs = [doc]

        let material = tab.artifactMaterial(for: entry)

        XCTAssertEqual(String(data: material!.data, encoding: .utf8), "loaded result")
        XCTAssertEqual(material?.presentation, "file-snapshot")
        XCTAssertEqual(tab.artifactSize(for: entry), Int64(material!.data.count))
    }

    @MainActor
    func testSnapshotAfterSaveStillUsesTheEditedVersion() {
        let tab = FileTab(machine: machine(), sourcePanel: panel())
        let entry = file(name: "verdict.txt", size: 4)
        let doc = OpenDoc(
            path: entry.path,
            name: entry.name,
            content: .text("old", name: entry.name, path: entry.path)
        )
        doc.loadedText("old")
        doc.editorChanged("new saved value")
        doc.markSaved()
        tab.openDocs = [doc]

        let material = tab.artifactMaterial(for: entry)

        XCTAssertEqual(String(data: material!.data, encoding: .utf8), "new saved value")
        XCTAssertEqual(material?.presentation, "file-snapshot")
    }

    @MainActor
    func testManualFilesTabRequestsDestinationInsteadOfSavingImplicitly() {
        let model = FilesModel()
        let tab = FileTab(machine: machine())
        model.tabs = [tab]
        model.activeID = tab.id
        let artifacts = ArtifactStore(loadImmediately: false, logEvents: false)
        let entry = file(name: "report.pdf", size: 200)

        model.requestArtifact(entry, from: tab, artifacts: artifacts)

        XCTAssertEqual(model.pendingArtifact?.entry, entry)
        XCTAssertNil(model.pendingArtifact?.suggestedPanel)
        XCTAssertFalse(model.pendingArtifact?.requiresLargeConfirmation ?? true)
    }

    @MainActor
    func testLargeSessionFileRequiresConfirmationAndKeepsPanelDestination() {
        let destination = panel()
        let model = FilesModel()
        let tab = FileTab(machine: machine(), sourcePanel: destination)
        model.tabs = [tab]
        let artifacts = ArtifactStore(loadImmediately: false, logEvents: false)
        let entry = file(name: "checkpoint.bin", size: FilesModel.largeArtifactThreshold + 1)

        model.requestArtifact(entry, from: tab, artifacts: artifacts)

        XCTAssertEqual(model.pendingArtifact?.suggestedPanel, destination)
        XCTAssertTrue(model.pendingArtifact?.requiresLargeConfirmation ?? false)
    }

    private func machine() -> Machine {
        Machine(
            id: "local",
            name: "this mac",
            host: "mac.local",
            os: "darwin",
            isLocal: true,
            httpBase: "http://127.0.0.1:1",
            wsBase: "ws://127.0.0.1:1"
        )
    }

    private func panel() -> ArtifactPanelContext {
        ArtifactPanelContext(
            machineID: "local",
            machineName: "this mac",
            machineHost: "mac.local",
            sessionName: "spatial_sol",
            stableSessionID: "$4",
            folder: "/workspace"
        )
    }

    private func file(name: String, size: Int64) -> FileEntry {
        FileEntry(
            name: name,
            path: "/workspace/" + name,
            isDir: false,
            size: size,
            mtime: 0,
            mode: "0644"
        )
    }
}
