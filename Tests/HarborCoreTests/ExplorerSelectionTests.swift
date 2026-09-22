import XCTest
@testable import HarborCore

final class ExplorerSelectionTests: XCTestCase {
    let rows = ["a", "b", "c", "d", "e"]

    func testCommandToggleAndPlainClick() {
        var selection = ExplorerSelection()
        selection.select("b"); selection.toggle("d")
        XCTAssertEqual(selection.paths, ["b", "d"])
        selection.toggle("b")
        XCTAssertEqual(selection.paths, ["d"])
        XCTAssertEqual(selection.focusedPath, "b")
        selection.select("c")
        XCTAssertEqual(selection.paths, ["c"])
        XCTAssertEqual(selection.anchorPath, "c")
        selection.toggle("c")
        XCTAssertTrue(selection.paths.isEmpty)
    }

    func testShiftUsesStableAnchorAndCanShrinkOrReverseRange() {
        var selection = ExplorerSelection(); selection.select("c")
        selection.extend(to: "e", in: rows)
        XCTAssertEqual(selection.paths, ["c", "d", "e"])
        selection.extend(to: "d", in: rows)
        XCTAssertEqual(selection.paths, ["c", "d"])
        selection.extend(to: "a", in: rows)
        XCTAssertEqual(selection.paths, ["a", "b", "c"])
        XCTAssertEqual(selection.anchorPath, "c")
        selection.toggle("e")
        selection.extend(to: "d", in: rows, additive: true)
        XCTAssertEqual(selection.paths, Set(rows))
    }

    func testHiddenAndDeletedPathsCannotRemainInSelection() {
        var selection = ExplorerSelection(); selection.selectAll(rows)
        selection.reconcile(with: ["b", "d"])
        XCTAssertEqual(selection.paths, ["b", "d"])
        XCTAssertEqual(selection.focusedPath, "b")
        selection.extend(to: "d", in: ["b", "d"])
        XCTAssertEqual(selection.paths, ["b", "d"])
        selection.reconcile(with: [])
        XCTAssertTrue(selection.paths.isEmpty)
        XCTAssertNil(selection.focusedPath); XCTAssertNil(selection.anchorPath)
        selection.extend(to: "c", in: rows)
        XCTAssertEqual(selection.paths, ["c"])
    }

    func testRenameAndDeletionPreserveOtherSelectedItems() {
        var selection = ExplorerSelection(); selection.select("a"); selection.toggle("c")
        selection.remap { $0 == "c" ? "renamed" : $0 }
        XCTAssertEqual(selection.paths, ["a", "renamed"])
        XCTAssertEqual(selection.focusedPath, "renamed")
        XCTAssertEqual(selection.anchorPath, "renamed")
        selection.remap { $0 == "a" ? nil : $0 }
        XCTAssertEqual(selection.paths, ["renamed"])
    }
}
