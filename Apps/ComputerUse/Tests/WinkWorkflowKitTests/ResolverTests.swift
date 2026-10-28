import Foundation
import Testing
@testable import WinkWorkflowKit

@Suite struct ResolverTests {
    func observation(_ elements: [ElementObservation], window: WindowObservation? = WindowObservation(title: "Main")) -> UIObservation {
        var list = elements
        for i in list.indices { list[i].handle = 500 + i }
        return UIObservation(bundleId: "com.example.app", pid: 1, appName: "App", window: window, elements: list)
    }

    @Test func uniqueIdentifierWins() {
        let obs = self.observation([Fixtures.button("Save", id: "save"), Fixtures.button("Save", id: "save-as")])
        let r = SelectorResolver.resolve(ElementLocator(role: "AXButton", identifier: "save", title: "Save"), in: obs)
        #expect(r.element?.identifier == "save")
        #expect(r.strategy == .identifier)
    }

    @Test func ambiguousNameIsRefused() {
        let obs = self.observation([Fixtures.button("Delete"), Fixtures.button("Delete")])
        let r = SelectorResolver.resolve(ElementLocator(role: "AXButton", title: "Delete"), in: obs)
        guard case let .ambiguous(candidates) = r.outcome else {
            Issue.record("expected ambiguity, got \(r.outcome)")
            return
        }
        #expect(candidates.count == 2)
    }

    @Test func ancestorContextDisambiguates() {
        let toolbar = AncestorLocator(role: "AXToolbar", title: "Main toolbar")
        let sheet = AncestorLocator(role: "AXSheet", title: "Confirm")
        let obs = self.observation([Fixtures.button("Delete", ancestors: [toolbar]), Fixtures.button("Delete", ancestors: [sheet])])
        let r = SelectorResolver.resolve(ElementLocator(role: "AXButton", title: "Delete", ancestors: [sheet]), in: obs)
        #expect(r.element?.ancestors.first == sheet)
        #expect(r.strategy == .semanticContext)
    }

    @Test func survivesReorderedSiblingsAndGeometry() {
        let locator = ElementLocator(role: "AXButton", title: "Save")
        let a = self.observation([Fixtures.button("Cancel"), Fixtures.button("Save")])
        let b = self.observation([
            Fixtures.button("Save", frame: Rect(x: 400, y: 300, width: 120, height: 30)),
            Fixtures.button("Help"), Fixtures.button("Cancel"),
        ], window: WindowObservation(title: "Main", frame: Rect(x: 900, y: 100, width: 1200, height: 800)))
        #expect(SelectorResolver.resolve(locator, in: a).element?.title == "Save")
        #expect(SelectorResolver.resolve(locator, in: b).element?.frame?.x == 400)
    }

    @Test func differentIdentifierIsNotTheSameControl() {
        let obs = self.observation([Fixtures.button("Save", id: "export")])
        let r = SelectorResolver.resolve(ElementLocator(role: "AXButton", identifier: "save", title: "Save"), in: obs)
        guard case .notFound = r.outcome else {
            Issue.record("a button with another identifier must not match")
            return
        }
    }

    @Test func normalizedNameIsLowerConfidence() {
        let obs = self.observation([Fixtures.button("Save  Document…")])
        let r = SelectorResolver.resolve(ElementLocator(role: "AXButton", title: "save document"), in: obs)
        #expect(r.strategy == .normalized)
        #expect(r.confidence < 0.9)
    }

    @Test func coordinateFallbackOnlyWhenAllowed() {
        let obs = self.observation([], window: WindowObservation(title: "Main", frame: Rect(x: 0, y: 0, width: 100, height: 100)))
        let l = ElementLocator(point: RelativePoint(x: 5, y: 5))
        guard case .notFound = SelectorResolver.resolve(l, in: obs).outcome else {
            Issue.record("coordinates must not be used without authorization")
            return
        }
        guard case .coordinate = SelectorResolver.resolve(l, in: obs, allowCoordinateFallback: true).outcome else {
            Issue.record("authorized fallback should resolve to coordinates")
            return
        }
    }

    @Test func locatorBuilderDropsDynamicIdentifiersAndFieldContents() {
        let display = ElementObservation(handle: 9, role: "AXScrollArea", identifier: "StandardInputView;value:15")
        #expect(LocatorBuilder.locator(for: display).identifier == nil)
        let field = Fixtures.field(placeholder: "Search", value: "my private text")
        let l = LocatorBuilder.locator(for: field)
        #expect(l.label == nil)
        #expect(l.placeholder == "Search")
        let label = Fixtures.text("Total")
        #expect(LocatorBuilder.locator(for: label).label == "Total")
        let secure = Fixtures.field(placeholder: "Password", value: "hunter2", secure: true)
        #expect(secure.value == nil)
    }

    @Test func conditionsEvaluate() {
        let obs = self.observation([Fixtures.text("15", description: "result")], window: WindowObservation(title: "Calc — Doc"))
        let equals = Condition(kind: .valueEquals, target: ElementLocator(role: "AXStaticText", description: "result"), value: "15")
        #expect(ConditionEvaluator.evaluate(equals, in: obs).satisfied)
        let wrong = Condition(kind: .valueEquals, target: ElementLocator(role: "AXStaticText", description: "result"), value: "16")
        #expect(!ConditionEvaluator.evaluate(wrong, in: obs).satisfied)
        #expect(ConditionEvaluator.evaluate(Condition(kind: .windowTitleContains, value: "doc"), in: obs).satisfied)
        let absent = Condition(kind: .elementAbsent, target: ElementLocator(role: "AXButton", title: "Nope"))
        #expect(ConditionEvaluator.evaluate(absent, in: obs).satisfied)
    }
}

@Suite struct TemplateTests {
    @Test func rendersAndEscapes() throws {
        #expect(try Template.render("Hi ${name}!", inputs: ["name": "Ada"]) == "Hi Ada!")
        #expect(try Template.render("cost $${x}", inputs: [:]) == "cost ${x}")
        #expect(try Template.render(Template.escape("a ${b} c"), inputs: [:]) == "a ${b} c")
        #expect(throws: Template.Problem.self) { try Template.render("${missing}", inputs: [:]) }
        #expect(throws: Template.Problem.self) { try Template.references(in: "${unterminated") }
        #expect(throws: Template.Problem.self) { try Template.references(in: "${a b}") }
    }
}
