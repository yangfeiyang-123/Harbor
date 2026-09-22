import XCTest
@testable import HarborCore

final class TerminalArrangementTests: XCTestCase {
    func testListReorderingPreservesSpatialLayoutAndGroupFocus() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var layout = TerminalArrangement(); layout.insert(a); layout.split(a, adding: b, axis: .columns)
        layout.insert(c); layout.split(c, adding: d, axis: .rows)
        let originalGroups = layout.groups, selected = layout.selectedID
        XCTAssertTrue(layout.moveSession(d, relativeTo: a, after: false))
        XCTAssertEqual(layout.sessionIDs, [d, a, b, c])
        XCTAssertEqual(layout.groups, originalGroups.reversed())
        XCTAssertEqual(layout.selectedID, selected)
        XCTAssertTrue(layout.moveSession(b, relativeTo: a, after: false))
        XCTAssertEqual(layout.sessionIDs, [d, b, a, c])
        XCTAssertEqual(layout.groups, originalGroups.reversed(), "List sorting must not alter either split tree")
        XCTAssertTrue(layout.moveGroup(originalGroups[0].id, relativeTo: originalGroups[1].id, after: false))
        XCTAssertEqual(layout.sessionIDs, [b, a, d, c])
        XCTAssertEqual(layout.groups, originalGroups)
        let unchanged = layout
        XCTAssertFalse(layout.moveGroup(UUID(), relativeTo: originalGroups[0].id, after: false))
        XCTAssertFalse(layout.moveSession(a, relativeTo: a, after: true))
        XCTAssertFalse(layout.moveSession(a, relativeTo: UUID(), after: true))
        XCTAssertEqual(layout, unchanged)
    }

    func testMergingGroupsRetainsNestedRatiosAndDestinationTabThenClosesCleanly() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        var layout = TerminalArrangement(); layout.insert(a); layout.split(a, adding: b, axis: .columns)
        let targetID = try XCTUnwrap(layout.selectedGroup?.id)
        layout.setTitle("Training", for: targetID); layout.setTabWidth(230, for: targetID)
        guard case .split(let splitID, _, _, _, _) = layout.visible else { return XCTFail() }
        layout.resize(splitID, ratio: 0.3)
        layout.insert(c); layout.split(c, adding: d, axis: .rows)
        guard case .split(let sourceSplit, _, _, _, _) = layout.visible else { return XCTFail() }
        layout.resize(sourceSplit, ratio: 0.7)
        let source = try XCTUnwrap(layout.selectedGroup)
        layout.insert(e); let independent = try XCTUnwrap(layout.selectedGroup)
        XCTAssertTrue(layout.mergeGroup(source.id, into: targetID, axis: .rows, before: true, beside: b))
        let target = try XCTUnwrap(layout.selectedGroup)
        XCTAssertEqual(target.id, targetID); XCTAssertEqual(target.title, "Training"); XCTAssertEqual(target.tabWidth, 230)
        XCTAssertEqual(target.selectedID, d); XCTAssertEqual(layout.sessionIDs, [a, c, d, b, e])
        guard case .split(let outerID, .columns, let ratio, .terminal(let first), let right) = target.layout,
              case .split(_, .rows, _, let inserted, .terminal(let last)) = right else { return XCTFail() }
        XCTAssertEqual(outerID, splitID); XCTAssertEqual(ratio, 0.3); XCTAssertEqual(first, a); XCTAssertEqual(last, b)
        XCTAssertEqual(inserted, source.layout, "The entire dragged tree must survive")
        XCTAssertEqual(layout.groups.last, independent)
        layout.remove(c); layout.remove(d)
        XCTAssertEqual(layout.groups.first?.layout, .split(id: splitID, axis: .columns, ratio: 0.3, first: .terminal(a), second: .terminal(b)))
        let unchanged = layout
        XCTAssertFalse(layout.mergeGroup(targetID, into: targetID, axis: .columns))
        XCTAssertFalse(layout.mergeGroup(independent.id, into: targetID, axis: .rows, beside: UUID()))
        XCTAssertEqual(layout, unchanged)
    }

    func testMixedReorderMergeSplitAndReconnectNeverLosesOrDuplicatesSessions() throws {
        var layout = TerminalArrangement()
        (0..<8).forEach { _ in layout.insert(UUID()) }
        var seed: UInt64 = 91
        func next(_ limit: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(limit)) }
        for _ in 0..<500 {
            let ids = layout.sessionIDs, a = ids[next(ids.count)], b = ids[next(ids.count)]
            switch next(7) {
            case 0: layout.moveSession(a, relativeTo: b, after: next(2) == 0)
            case 1:
                let groups = layout.groups
                layout.moveGroup(groups[next(groups.count)].id, relativeTo: groups[next(groups.count)].id, after: next(2) == 0)
            case 2:
                let groups = layout.groups
                layout.mergeGroup(groups[next(groups.count)].id, into: groups[next(groups.count)].id, axis: .columns)
            case 3: layout.split(a, adding: b, axis: .rows, before: next(2) == 0)
            case 4: layout.separate(a)
            case 5: layout.replace(a, with: UUID())
            default: layout.remove(a); layout.insert(UUID())
            }
            let leaves = layout.roots.flatMap(\.sessionIDs)
            XCTAssertEqual(leaves.count, 8); XCTAssertEqual(Set(leaves).count, 8)
            XCTAssertEqual(Set(layout.sessionIDs), Set(leaves)); XCTAssertEqual(layout.sessionIDs.count, 8)
            XCTAssertEqual(Set(layout.groups.map(\.id)).count, layout.groups.count)
            XCTAssertTrue(layout.groups.allSatisfy { $0.layout.contains($0.selectedID) })
            XCTAssertTrue(layout.visible?.contains(try XCTUnwrap(layout.selectedID)) == true)
        }
    }
    func testSplitGroupKeepsOneTabItsIdentityAndLastFocus() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), replacement = UUID()
        var layout = TerminalArrangement(); layout.insert(a)
        let groupID = try XCTUnwrap(layout.selectedGroup?.id)
        layout.setTitle("Training", for: groupID); layout.setTabWidth(240, for: groupID)
        layout.split(a, adding: b, axis: .columns); layout.split(b, adding: c, axis: .rows)
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.selectedGroup?.id, groupID)
        layout.select(b); let tree = layout.visible
        layout.insert(d); let independentID = try XCTUnwrap(layout.selectedGroup?.id)
        XCTAssertEqual(layout.groups.count, 2)
        layout.selectGroup(groupID)
        XCTAssertEqual(layout.selectedID, b); XCTAssertEqual(layout.visible, tree)
        layout.selectGroup(independentID); layout.remove(b)
        XCTAssertEqual(layout.selectedID, d, "Closing an inactive pane cannot steal focus")
        layout.selectGroup(groupID); XCTAssertEqual(layout.selectedID, c)
        layout.replace(a, with: replacement); layout.remove(replacement)
        XCTAssertEqual(layout.selectedGroup?.id, groupID)
        XCTAssertEqual(layout.selectedGroup?.title, "Training"); XCTAssertEqual(layout.selectedGroup?.tabWidth, 240)
        XCTAssertEqual(layout.visible, .terminal(c))
        layout.remove(c); XCTAssertEqual(layout.selectedGroup?.id, independentID)
    }
    func testSeparatingOriginalPaneCreatesDistinctTabIdentity() throws {
        let a = UUID(), b = UUID()
        var layout = TerminalArrangement(); layout.insert(a); layout.split(a, adding: b, axis: .rows)
        let originalGroup = try XCTUnwrap(layout.selectedGroup?.id)
        layout.separate(a)
        XCTAssertEqual(layout.groups.count, 2)
        XCTAssertEqual(Set(layout.groups.map(\.id)).count, 2)
        XCTAssertEqual(layout.groups.first?.id, originalGroup)
        let standalone = layout.selectedGroup
        layout.separate(a); XCTAssertEqual(layout.selectedGroup, standalone)
    }
    func testNestedColumnsAndRowsRetainOrderAndCollapseOnlyClosedPane() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), independent = UUID()
        var layout = TerminalArrangement(); layout.insert(a)
        XCTAssertTrue(layout.split(a, adding: b, axis: .columns))
        XCTAssertTrue(layout.split(b, adding: c, axis: .columns))
        XCTAssertTrue(layout.split(b, adding: d, axis: .rows))
        XCTAssertEqual(layout.visible?.sessionIDs, [a, b, d, c])
        guard case .split(let firstSplit, .columns, _, _, _) = layout.visible else { return XCTFail("Expected columns") }
        layout.resize(firstSplit, ratio: 0.33)
        let before = layout.visible
        layout.insert(independent); XCTAssertEqual(layout.visible, .terminal(independent))
        layout.select(d); XCTAssertEqual(layout.visible, before)
        layout.remove(d)
        XCTAssertEqual(layout.roots.first?.sessionIDs, [a, b, c])
        XCTAssertEqual(layout.sessionIDs, [a, b, c, independent])
        XCTAssertTrue(layout.visible?.contains(layout.selectedID!) == true)
        layout.remove(a); layout.remove(b); layout.remove(c)
        XCTAssertEqual(layout.roots, [.terminal(independent)])
        layout.remove(independent); XCTAssertTrue(layout.roots.isEmpty); XCTAssertNil(layout.selectedID)
    }
    func testReconnectReplacementPreservesSplitIdentityAndRatios() throws {
        let a = UUID(), b = UUID(), replacement = UUID()
        var layout = TerminalArrangement(); layout.insert(a); layout.split(a, adding: b, axis: .rows)
        guard case .split(let id, _, _, _, _) = layout.visible else { return XCTFail() }
        layout.resize(id, ratio: 0.7); layout.replace(b, with: replacement)
        XCTAssertEqual(layout.visible, .split(id: id, axis: .rows, ratio: 0.7, first: .terminal(a), second: .terminal(replacement)))
        XCTAssertEqual(layout.selectedID, replacement)
    }
    func testSeparateAndResplitNeverDuplicatesSessionsOrLosesNeighbors() {
        let a = UUID(), b = UUID(), c = UUID()
        var layout = TerminalArrangement(); layout.insert(a); layout.split(a, adding: b, axis: .columns); layout.insert(c)
        layout.separate(b); XCTAssertEqual(layout.roots, [.terminal(a), .terminal(c), .terminal(b)])
        layout.split(a, adding: b, axis: .rows)
        XCTAssertEqual(layout.sessionIDs, [a, b, c]); XCTAssertEqual(Set(layout.sessionIDs).count, 3)
        let before = layout
        XCTAssertFalse(layout.split(a, adding: a, axis: .rows)); XCTAssertEqual(layout, before)
        XCTAssertFalse(layout.split(UUID(), adding: UUID(), axis: .columns)); XCTAssertEqual(layout, before)
    }
}
