import Foundation

public enum ResolutionStrategy: String, Codable, Sendable {
    case identifier
    case roleName = "role_name"
    case semanticContext = "semantic_context"
    case normalized
    case roleUnique = "role_unique"
    case coordinate
}

public struct Resolution: Sendable {
    public enum Outcome: Sendable {
        case unique(ElementObservation)
        case ambiguous([ElementObservation])
        case notFound
        /// Only when the step and the run both allow the coordinate fallback.
        case coordinate(RelativePoint)
    }

    public var outcome: Outcome
    public var strategy: ResolutionStrategy?
    public var confidence: Double
    /// Elements that almost matched, for TARGET_NOT_FOUND diagnostics.
    public var nearMisses: [ElementObservation] = []

    public var element: ElementObservation? {
        if case let .unique(e) = self.outcome { return e }
        return nil
    }
}

/// Deterministic, fail-closed matching of a semantic locator against a normalized observation.
/// Priority: unique identifier -> role + exact name -> + ancestor context -> normalized name -> role alone
/// -> (explicitly authorized) coordinates. More than one plausible element is never resolved by picking one.
public enum SelectorResolver {
    public static func resolve(_ locator: ElementLocator, in observation: UIObservation,
                               allowCoordinateFallback: Bool = false) -> Resolution {
        let pool = observation.elements.filter { e in
            (locator.role == nil || e.role == locator.role) && (locator.subrole == nil || e.subrole == locator.subrole)
        }

        // 1. Exact identifier.
        if let identifier = locator.identifier {
            let byID = pool.filter { $0.identifier == identifier }
            if byID.count == 1 { return Resolution(outcome: .unique(byID[0]), strategy: .identifier, confidence: 1) }
            if byID.count > 1 {
                let narrowed = byID.filter { self.namesMatch(locator, $0, normalized: false) && self.ancestorsMatch(locator, $0) }
                if narrowed.count == 1 {
                    return Resolution(outcome: .unique(narrowed[0]), strategy: .identifier, confidence: 1)
                }
                return Resolution(outcome: .ambiguous(narrowed.isEmpty ? byID : narrowed), strategy: .identifier,
                                  confidence: 0)
            }
        }
        // An element carrying a different identifier is a different control, even if its name matches.
        let candidates = pool.filter { e in
            locator.identifier == nil || e.identifier == nil || e.identifier == locator.identifier
        }
        let idPenalty = locator.identifier == nil ? 0 : 0.1

        if locator.hasNameFields {
            // 2. Role + exact name.
            let exact = candidates.filter { self.namesMatch(locator, $0, normalized: false) }
            if exact.count == 1, self.ancestorsMatch(locator, exact[0]) {
                return Resolution(outcome: .unique(exact[0]), strategy: .roleName, confidence: 0.95 - idPenalty)
            }
            // 3. Disambiguate with ancestor context.
            if exact.count >= 1 {
                let inContext = exact.filter { self.ancestorsMatch(locator, $0) }
                if inContext.count == 1 {
                    return Resolution(outcome: .unique(inContext[0]), strategy: .semanticContext,
                                      confidence: 0.9 - idPenalty)
                }
                if inContext.count > 1 {
                    return Resolution(outcome: .ambiguous(inContext), strategy: .semanticContext, confidence: 0)
                }
            }
            // 4. Normalized (case/whitespace-insensitive) name, still unique and in context.
            let loose = candidates.filter { self.namesMatch(locator, $0, normalized: true) && self.ancestorsMatch(locator, $0) }
            if loose.count == 1 {
                return Resolution(outcome: .unique(loose[0]), strategy: .normalized, confidence: 0.75 - idPenalty)
            }
            if loose.count > 1 {
                return Resolution(outcome: .ambiguous(loose), strategy: .normalized, confidence: 0)
            }
        } else if locator.identifier == nil, locator.role != nil {
            // 5. Role alone (plus ancestors) when the locator carries no name at all.
            let inContext = candidates.filter { self.ancestorsMatch(locator, $0) }
            if inContext.count == 1 {
                return Resolution(outcome: .unique(inContext[0]), strategy: .roleUnique, confidence: 0.8)
            }
            if inContext.count > 1 {
                return Resolution(outcome: .ambiguous(inContext), strategy: .roleUnique, confidence: 0)
            }
        }

        if allowCoordinateFallback, let point = locator.point, observation.window?.frame != nil {
            return Resolution(outcome: .coordinate(point), strategy: .coordinate, confidence: 0.3)
        }
        return Resolution(outcome: .notFound, strategy: nil, confidence: 0,
                          nearMisses: self.nearMisses(locator, observation))
    }

    /// Every name field the locator specifies must match.
    static func namesMatch(_ l: ElementLocator, _ e: ElementObservation, normalized: Bool) -> Bool {
        func eq(_ want: String?, _ have: String?) -> Bool {
            guard let want else { return true }
            guard let have else { return false }
            return normalized ? self.normalize(want) == self.normalize(have) : want == have
        }
        return eq(l.title, e.title) && eq(l.description, e.description) && eq(l.placeholder, e.placeholder)
            && eq(l.label, e.visibleLabel)
    }

    /// The locator's ancestors must appear, in order, among the element's ancestors (nearest first).
    static func ancestorsMatch(_ l: ElementLocator, _ e: ElementObservation) -> Bool {
        guard let wanted = l.ancestors, !wanted.isEmpty else { return true }
        var index = 0
        for want in wanted {
            var found = false
            while index < e.ancestors.count {
                let have = e.ancestors[index]
                index += 1
                if have.role == want.role, want.identifier == nil || have.identifier == want.identifier,
                   want.title == nil || have.title == want.title,
                   want.description == nil || have.description == want.description {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "…:."))
    }

    private static func nearMisses(_ l: ElementLocator, _ o: UIObservation) -> [ElementObservation] {
        let names = [l.title, l.description, l.label, l.placeholder, l.identifier].compactMap { $0 }.map(self.normalize)
        let scored: [(ElementObservation, Int)] = o.elements.compactMap { e in
            var score = 0
            if let role = l.role, e.role == role { score += 1 }
            let have = [e.title, e.description, e.visibleLabel, e.placeholder, e.identifier].compactMap { $0 }
                .map(self.normalize)
            for name in names where !name.isEmpty {
                if have.contains(name) { score += 3 } else if have.contains(where: { $0.contains(name) || name.contains($0) && !$0.isEmpty }) {
                    score += 1
                }
            }
            return score >= 2 ? (e, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }
}

public extension WindowMatcher {
    func matches(_ window: WindowObservation?) -> Bool {
        guard let window else { return self.title == nil && self.titleContains == nil && self.role == nil }
        if let title, window.title != title { return false }
        if let titleContains, !(window.title ?? "").localizedCaseInsensitiveContains(titleContains) { return false }
        if let role, window.role != role { return false }
        if let subrole, window.subrole != subrole { return false }
        return true
    }
}

public struct ConditionResult: Sendable {
    public var satisfied: Bool
    public var detail: String
}

public enum ConditionEvaluator {
    /// `condition` must already have its templates rendered.
    public static func evaluate(_ condition: Condition, in observation: UIObservation) -> ConditionResult {
        guard let kind = condition.parsedKind else {
            return ConditionResult(satisfied: false, detail: "unknown condition kind '\(condition.kind)'")
        }
        switch kind {
        case .windowTitleContains:
            let title = observation.window?.title ?? ""
            let want = condition.value ?? ""
            let ok = title.localizedCaseInsensitiveContains(want)
            return ConditionResult(satisfied: ok, detail: ok ? "window title matches" : "window title does not contain the expected text")
        case .elementExists, .elementAbsent:
            guard let target = condition.target else { return ConditionResult(satisfied: false, detail: "missing target") }
            let count = self.matchCount(target, observation)
            let exists = count > 0
            if kind == .elementExists {
                return ConditionResult(satisfied: exists, detail: exists ? "\(target.summary) present" : "\(target.summary) not present")
            }
            return ConditionResult(satisfied: !exists, detail: exists ? "\(target.summary) still present" : "\(target.summary) absent")
        case .valueEquals, .valueContains, .elementEnabled:
            guard let target = condition.target else { return ConditionResult(satisfied: false, detail: "missing target") }
            let resolution = SelectorResolver.resolve(target, in: observation)
            switch resolution.outcome {
            case let .unique(element):
                if kind == .elementEnabled {
                    return ConditionResult(satisfied: element.enabled, detail: element.enabled ? "enabled" : "disabled")
                }
                if element.secure {
                    return ConditionResult(satisfied: false, detail: "secure fields cannot be read")
                }
                let have = element.value ?? element.title ?? element.description ?? ""
                let want = condition.value ?? ""
                let ok = kind == .valueEquals ? have == want : have.contains(want)
                return ConditionResult(satisfied: ok, detail: ok ? "value matches" : "value differs from the expected value")
            case .ambiguous:
                return ConditionResult(satisfied: false, detail: "\(target.summary) is ambiguous")
            case .notFound, .coordinate:
                return ConditionResult(satisfied: false, detail: "\(target.summary) not found")
            }
        }
    }

    /// How many elements plausibly match (identifier or exact/normalized name in context).
    static func matchCount(_ target: ElementLocator, _ observation: UIObservation) -> Int {
        switch SelectorResolver.resolve(target, in: observation).outcome {
        case .unique: 1
        case let .ambiguous(all): all.count
        case .notFound, .coordinate: 0
        }
    }
}

/// Builds persistent locators from observed elements at the action boundary.
public enum LocatorBuilder {
    /// Identifiers that embed changing state ("StandardInputView;value:15", UUIDs, counters) are useless
    /// as persistent selectors and are dropped.
    public static func isStableIdentifier(_ id: String) -> Bool {
        if id.isEmpty || id.count > 80 || id.hasPrefix("_NS:") { return false }
        if id.contains(";") || id.contains("value:") || id.contains("\n") { return false }
        if id.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil { return false }
        if id.range(of: #"\d{5,}"#, options: .regularExpression) != nil { return false }
        return true
    }

    public static func locator(for element: ElementObservation, window: WindowObservation? = nil,
                               includePoint: Bool = false) -> ElementLocator {
        var l = ElementLocator(role: element.role)
        if let s = element.subrole, s != "AXUnknown" { l.subrole = s }
        if let id = element.identifier, self.isStableIdentifier(id) { l.identifier = id }
        l.title = element.title.map { Redactor.clip($0, 200) }
        l.description = element.description.map { Redactor.clip($0, 200) }
        l.placeholder = element.placeholder.map { Redactor.clip($0, 200) }
        // A static text's value is its name, but only when nothing else names it.
        if l.identifier == nil, l.title == nil, l.description == nil, let label = element.visibleLabel,
           label.count <= 120, !Redactor.looksSecret(label) {
            l.label = label
        }
        let context = element.ancestors.map { a -> AncestorLocator in
            var copy = a
            if let id = a.identifier, !self.isStableIdentifier(id) { copy.identifier = nil }
            return copy
        }.filter(\.hasSemantics).prefix(2)
        if !context.isEmpty { l.ancestors = Array(context) }
        if includePoint, let frame = element.frame { l.point = RelativePoint(x: frame.midX, y: frame.midY) }
        return l
    }
}
