@testable import BiliKit
import XCTest

final class InteractiveTests: XCTestCase {
    private func edge() throws -> StoryEdge {
        StoryEdge(json: try JSON(data: Fixture.data("story_edge.json"))["data"])
    }

    func testParsesEdge() throws {
        let e = try edge()
        XCTAssertEqual(e.edgeID, 5_556_092)
        XCTAssertEqual(e.title, "4")
        XCTAssertFalse(e.isLeaf)
        XCTAssertEqual(e.questions.count, 1)
        XCTAssertNil(e.questions[0].timeLimit)
        XCTAssertEqual(e.questions[0].choices.map(\.edgeID), [5_556_133, 5_556_134, 5_556_135])
        XCTAssertEqual(e.questions[0].choices[0].cid, 125_499_249)
        XCTAssertTrue(e.questions[0].choices[0].isDefault)
        XCTAssertEqual(e.variables.map(\.id), ["H7g_64_PG2EVS", "score"])
        XCTAssertTrue(e.variables[0].isRandom)
    }

    func testLeafWithoutQuestions() {
        let e = StoryEdge(json: JSON(["edge_id": 9, "title": "结局", "is_leaf": 1, "edges": [:]] as [String: Any]))
        XCTAssertTrue(e.isLeaf)
        XCTAssertTrue(e.questions.isEmpty)
    }

    func testConditionsPickChoices() throws {
        let e = try edge()
        var state = StoryState()
        state.enter(e) // random var = 42 from the fixture
        let q = e.questions[0]
        XCTAssertEqual(state.visibleChoices(q).map(\.text), [q.choices[0].text, q.choices[2].text])
        XCTAssertEqual(state.automaticChoice(q)?.edgeID, 5_556_133)
    }

    func testActionsCarryAcrossModules() throws {
        let e = try edge()
        var state = StoryState()
        state.enter(e)
        XCTAssertEqual(state.values["score"], 10)
        state.choose(StoryEdge.Choice(edgeID: 1, cid: 1, text: "", condition: "", action: "$score=$score+5; $flag = 1",
                                      isDefault: false, isHidden: false))
        XCTAssertEqual(state.values["score"], 15)
        XCTAssertEqual(state.values["flag"], 1)
        // Entering the next module keeps the carried value (Bilibili sends the initial one again).
        state.enter(e)
        XCTAssertEqual(state.values["score"], 15)
    }

    func testExpressions() throws {
        let v = ["a": 3.0, "b": 0.0]
        XCTAssertEqual(try StoryExpression.evaluate("$a+2*3", v), 9)
        XCTAssertEqual(try StoryExpression.evaluate("($a+2)*3", v), 15)
        XCTAssertEqual(try StoryExpression.evaluate("$a>=3.00 && $b<=0", v), 1)
        XCTAssertEqual(try StoryExpression.evaluate("$a==1 || $b!=0", v), 0)
        XCTAssertEqual(try StoryExpression.evaluate("-$a + $missing", v), -3)
        XCTAssertEqual(try StoryExpression.evaluate("!$b", v), 1)
        XCTAssertThrowsError(try StoryExpression.evaluate("$a >", v))
        XCTAssertThrowsError(try StoryExpression.evaluate("random()", v))
    }

    func testDollarPrefixedVariableIDs() {
        let e = StoryEdge(json: JSON(["edge_id": 2, "edges": [:],
                                      "hidden_vars": [["id_v2": "$abc", "value": 5, "type": 1]]] as [String: Any]))
        var state = StoryState()
        state.enter(e)
        XCTAssertEqual(state.values["abc"], 5)
        XCTAssertTrue(state.allows(StoryEdge.Choice(edgeID: 1, cid: 1, text: "", condition: "$abc==5", action: "", isDefault: false, isHidden: false)))
    }

    func testOnlyPlainAssignmentsRun() {
        var state = StoryState()
        state.choose(StoryEdge.Choice(edgeID: 1, cid: 1, text: "", condition: "", action: "$a>=1;$b==2;$c=3;$=4", isDefault: false, isHidden: false))
        XCTAssertEqual(state.values, ["c": 3])
    }

    func testUnreadableConditionDoesNotHideChoice() {
        let choice = StoryEdge.Choice(edgeID: 1, cid: 1, text: "", condition: "rand() > 2", action: "", isDefault: false, isHidden: false)
        XCTAssertTrue(StoryState().allows(choice))
    }

    func testGraphVersion() {
        XCTAssertEqual(API.storyGraphVersion(fromPlayerInfo: JSON(["interaction": ["graph_version": 155_446]])), 155_446)
        XCTAssertNil(API.storyGraphVersion(fromPlayerInfo: JSON(["interaction": [:] as [String: Any]])))
    }
}

final class HeatTests: XCTestCase {
    func testCounterBinsTimesOncePerSegment() {
        var counter = HeatCounter(duration: 600) // 600 / 240 = 2.5 → 3 s steps
        XCTAssertEqual(counter.step, 3)
        XCTAssertEqual(counter.segmentCount, 2)
        XCTAssertNil(counter.curve)
        XCTAssertTrue(counter.add(segment: 1, times: Array(repeating: 10.5, count: 30) + [-1, 700]))
        XCTAssertFalse(counter.add(segment: 1, times: Array(repeating: 10.5, count: 30)))
        XCTAssertNil(counter.curve, "too few comments yet")
        counter.add(segment: 2, times: Array(repeating: 400, count: 20))
        XCTAssertTrue(counter.isComplete)
        let curve = counter.curve
        XCTAssertEqual(curve?.values.count, 200)
        XCTAssertEqual(curve?.values[3], 30)
        XCTAssertEqual(curve?.values[133], 20)
    }

    func testShortVideoUsesTwoSecondSteps() {
        XCTAssertEqual(HeatCounter(duration: 90).step, 2)
        XCTAssertEqual(HeatCounter(duration: 90).segmentCount, 1)
        XCTAssertEqual(HeatCounter(duration: 360).segmentCount, 1)
        XCTAssertEqual(HeatCounter(duration: 7200).step, 10)
    }

    func testNormalizedPeaksAtOne() {
        let curve = HeatCurve(step: 1, values: [0, 0, 9, 0, 0])
        XCTAssertEqual(curve.normalized.max(), 1)
        XCTAssertEqual(curve.normalized.count, 5)
    }

    func testHighlightsAreSpacedAndSkipFlatCurves() {
        var values = [Double](repeating: 10, count: 200)
        values[50] = 200; values[51] = 180; values[52] = 190 // one burst, three samples
        values[120] = 150; values[121] = 160
        let curve = HeatCurve(step: 2, values: values)
        let peaks = curve.highlights(count: 3, spacing: 30)
        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(peaks[0], 100, accuracy: 4)
        XCTAssertEqual(peaks[1], 240, accuracy: 4)
        XCTAssertTrue(HeatCurve(step: 2, values: [Double](repeating: 10, count: 50) + [11]).highlights().isEmpty)
    }

    func testHighlightsSkipTheVeryEnd() {
        var values = [Double](repeating: 1, count: 100)
        values[99] = 100
        XCTAssertTrue(HeatCurve(step: 1, values: values).highlights(duration: 100).isEmpty)
    }
}
