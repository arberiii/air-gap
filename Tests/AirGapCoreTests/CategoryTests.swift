import XCTest
@testable import AirGapCore

final class CategoryTests: XCTestCase {
    func testStarterSet() {
        XCTAssertEqual(Categorization().categories.map(\.id),
                       ["social", "video", "productivity", "communication", "news", "shopping", "games", "other"])
    }

    func testBuiltInSuffixMatch() {
        let c = Categorization()
        XCTAssertEqual(c.categoryID(of: "web:m.youtube.com"), "video")
        XCTAssertEqual(c.categoryID(of: "web:reddit.com"), "social")
        XCTAssertEqual(c.categoryID(of: "web:github.com"), "productivity")
        XCTAssertEqual(c.categoryID(of: "web:notyoutube.com"), "other")
        XCTAssertEqual(c.categoryID(of: "app:com.tinyspeck.slackmacgap"), "communication")
    }

    func testResolutionOrder() {
        var c = Categorization()
        c.beginLabeling(["web:youtube.com"])
        c.applyAssistantLabels(["web:youtube.com": "social"], asked: ["web:youtube.com"])
        XCTAssertEqual(c.categoryID(of: "web:youtube.com"), "social")
        c.setUserCategory("games", for: ["web:youtube.com"])
        XCTAssertEqual(c.categoryID(of: "web:youtube.com"), "games")
    }

    func testDeleteFallsBackThroughOrder() throws {
        var c = Categorization()
        let learning = try XCTUnwrap(c.addCategory(named: "Learning"))
        c.setUserCategory(learning.id, for: ["web:youtube.com"])
        c.beginLabeling(["web:foo.dev"])
        c.applyAssistantLabels(["web:foo.dev": learning.id], asked: ["web:foo.dev"])
        XCTAssertEqual(c.categoryID(of: "web:foo.dev"), learning.id)
        c.deleteCategory(learning.id)
        XCTAssertFalse(c.categories.contains(learning))
        XCTAssertEqual(c.categoryID(of: "web:youtube.com"), "video")
        XCTAssertEqual(c.categoryID(of: "web:foo.dev"), "other")
    }

    func testOtherCannotBeDeleted() {
        var c = Categorization()
        c.deleteCategory(Categorization.otherID)
        XCTAssertTrue(c.categories.contains { $0.id == Categorization.otherID })
    }

    func testColorIndexStableAfterDelete() throws {
        var c = Categorization()
        let a = try XCTUnwrap(c.addCategory(named: "A"))
        let b = try XCTUnwrap(c.addCategory(named: "B"))
        XCTAssertEqual([a.colorIndex, b.colorIndex], [8, 9])
        c.deleteCategory(a.id)
        let added = try XCTUnwrap(c.addCategory(named: "C"))
        XCTAssertEqual(added.colorIndex, 8)
        XCTAssertEqual(c.categories.first { $0.id == b.id }?.colorIndex, 9)
        XCTAssertNil(c.addCategory(named: "  "))
    }

    func testRenameIgnoresEmpty() {
        var c = Categorization()
        c.renameCategory("social", to: "Friends")
        c.renameCategory("video", to: " ")
        XCTAssertEqual(c.category(of: "web:reddit.com").name, "Friends")
        XCTAssertEqual(c.category(of: "web:youtube.com").name, "Video & Entertainment")
    }

    func testNeedsLabel() {
        var c = Categorization()
        XCTAssertTrue(c.needsLabel("web:obscure.example"))
        XCTAssertFalse(c.needsLabel("web:youtube.com"))
        c.beginLabeling(["web:obscure.example"])
        c.applyAssistantLabels([:], asked: ["web:obscure.example"])
        XCTAssertFalse(c.needsLabel("web:obscure.example"))
    }

    func testLabelsArriveOnlyForPendingRequest() {
        var c = Categorization()
        let keys = ["web:obscure.example"]
        c.beginLabeling(keys)
        c = Categorization() // everything deleted while Claude was answering
        c.applyAssistantLabels(["web:obscure.example": "social"], asked: keys)
        XCTAssertTrue(c.assistantLabels.isEmpty)
        XCTAssertTrue(c.asked.isEmpty)
        c.beginLabeling(keys)
        c.applyAssistantLabels(["web:obscure.example": "social"], asked: keys)
        XCTAssertEqual(c.categoryID(of: "web:obscure.example"), "social")
    }

    func testForgetRemovesEveryTrace() {
        var c = Categorization()
        c.setUserCategory("games", for: ["web:a.example"])
        c.beginLabeling(["web:a.example"])
        c.applyAssistantLabels(["web:a.example": "social"], asked: ["web:a.example"])
        c.forget(key: "web:a.example")
        XCTAssertNil(c.userLabels["web:a.example"])
        XCTAssertNil(c.assistantLabels["web:a.example"])
        XCTAssertFalse(c.asked.contains("web:a.example"))
    }

    func testDecodesEmptyObject() throws {
        let c = try JSONDecoder().decode(Categorization.self, from: Data("{}".utf8))
        XCTAssertEqual(c, Categorization())
    }
}

final class CategoryPromptTests: XCTestCase {
    private let items: [(key: String, name: String)] = [("web:youtube.com", "youtube.com"), ("app:com.x", "X App")]

    func testPromptHasNamesOnly() {
        let prompt = Coach.categoryPrompt(items: items, categories: Categorization.starter)
        XCTAssertTrue(prompt.contains("web:youtube.com"))
        XCTAssertTrue(prompt.contains("X App"))
        XCTAssertTrue(prompt.contains("Video & Entertainment"))
        let stripped = items.reduce(prompt) { $0.replacingOccurrences(of: $1.key, with: "").replacingOccurrences(of: $1.name, with: "") }
        XCTAssertNil(stripped.rangeOfCharacter(from: .decimalDigits), stripped)
    }

    func testSchemaListsIDs() throws {
        let ids = ["social", "other"]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Coach.categorySchema(ids: ids).utf8)) as? [String: Any])
        let labels = try XCTUnwrap((json["properties"] as? [String: Any])?["labels"] as? [String: Any])
        let item = try XCTUnwrap(labels["items"] as? [String: Any])
        let category = try XCTUnwrap((item["properties"] as? [String: Any])?["category"] as? [String: Any])
        XCTAssertEqual(category["enum"] as? [String], ids)
    }

    func testLabelsFilterUnknown() {
        let answer = CoachCategoryAnswer(labels: [
            .init(key: "web:youtube.com", category: "video"),
            .init(key: "web:youtube2.com", category: "social"),
            .init(key: "app:com.x", category: "made-up"),
        ])
        let labels = Coach.categoryLabels(answer, asked: ["web:youtube.com", "app:com.x"], validIDs: ["video", "social", "other"])
        XCTAssertEqual(labels, ["web:youtube.com": "video"])
    }

    func testDecodeAnswerFromEnvelope() throws {
        let envelope = #"{"is_error":false,"structured_output":{"labels":[{"key":"web:youtube.com","category":"video"}]}}"#
        let answer = try Coach.decode(CoachCategoryAnswer.self, from: Data(envelope.utf8))
        XCTAssertEqual(answer.labels, [.init(key: "web:youtube.com", category: "video")])
    }
}
