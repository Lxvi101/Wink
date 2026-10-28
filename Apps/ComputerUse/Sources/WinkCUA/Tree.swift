import ApplicationServices
import Foundation
import WinkWorkflowKit

/// One rendered accessibility element. `key` is a structural identity used to keep indices stable
/// across observations, so unchanged elements keep their number and diffs stay small.
struct UINode {
    let element: AXUIElement
    let key: String
    let depth: Int
    let content: String
    let role: String
    let frame: CGRect?
    let actions: [String]
    var index: Int = 0
    // Typed attributes from the same batched AX read, kept for semantic locators (workflows). Never
    // reconstructed from `content`. `value` is nil for secure fields.
    var subrole: String?
    var identifier: String?
    var title: String?
    var desc: String?
    var placeholder: String?
    var value: String?
    var enabled = true
    var focused = false
    var editable = false
    var secure = false
    var selected = false
    /// Nearest-first named ancestors (windows excluded), at most three.
    var ancestors: [AncestorLocator] = []
}

struct TreeOptions {
    var maxNodes = 1500
    var maxDepth = 60
    var maxValueLength = 400
    var includeMenuBar = true
}

/// A walked accessibility tree for one window plus the app's menu bar.
struct TreeSnapshot {
    var nodes: [UINode]
    var windowTitle: String?
    var windowFrame: CGRect?
    var windowID: CGWindowID?
    var focusedSummary: String?
    var selectedText: String?
    var truncated: Bool

    var signature: Int {
        var hasher = Hasher()
        for node in nodes { hasher.combine(node.key); hasher.combine(node.content) }
        hasher.combine(selectedText)
        return hasher.finalize()
    }
}

enum TreeWalker {
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXScrollArea",
        "AXGrowArea", "AXMatte", "AXRuler", "AXList", "AXSplitter",
    ]
    private static let hiddenActions: Set<String> = [
        "AXPress", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI", "AXCancel", "AXConfirm",
    ]
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXSearchField",
    ]

    static func walk(app: AXUIElement, window: AXUIElement?, options: TreeOptions) -> TreeSnapshot {
        var nodes: [UINode] = []
        var ancestors: [AXUIElement] = [app] // cycle guard: some apps report themselves as their own child
        var truncated = false
        var focusedSummary: String?
        var context: [AncestorLocator] = [] // named, rendered ancestors of the element being visited

        func clip(_ s: String, _ limit: Int) -> String {
            let flat = s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
            guard flat.count > limit else { return flat }
            return String(flat.prefix(limit)) + "…(+\(flat.count - limit) chars)"
        }

        func visit(_ element: AXUIElement, depth: Int, parentKey: String, ordinals: inout [String: Int]) {
            if nodes.count >= options.maxNodes { truncated = true; return }
            if depth > options.maxDepth { truncated = true; return }
            let v = AX.attributes(element, AX.batchAttributes)
            let role = AX.string(v[0]) ?? "AXUnknown"
            let subrole = AX.string(v[1])
            let title = AX.string(v[2]).flatMap { $0.isEmpty ? nil : $0 }
            let desc = AX.string(v[3]).flatMap { $0.isEmpty ? nil : $0 }
            var value = role == "AXMenuBarItem" || role == "AXMenuItem" ? nil : AX.string(v[4])
            if value?.isEmpty == true { value = nil }
            let rawIdentifier = AX.string(v[5])
            let identifier = rawIdentifier.flatMap { $0.isEmpty || $0.hasPrefix("_NS:") ? nil : $0 }
            let enabled = AX.bool(v[6]) ?? true
            let focused = AX.bool(v[7]) ?? false
            let origin = AX.point(v[8])
            let size = AX.size(v[9])
            let children = (v[10] as? [AXUIElement]) ?? []
            let help = AX.string(v[11]).flatMap { $0.isEmpty ? nil : $0 }
            let placeholder = AX.string(v[12]).flatMap { $0.isEmpty ? nil : $0 }
            let selected = AX.bool(v[13]) ?? false
            let frame = origin.flatMap { o in size.map { CGRect(origin: o, size: $0) } }

            let hasText = title != nil || desc != nil || value != nil || identifier != nil || placeholder != nil
            let invisible = (size.map { $0.width <= 0 || $0.height <= 0 } ?? false) && children.isEmpty
            let flatten = invisible || (containerRoles.contains(role) && !hasText && !focused)
                || (role == "AXImage" && !hasText) || role == "AXRulerMarker"

            let base = "\(role):\(identifier ?? title ?? desc ?? "")"
            let ordinal = ordinals[base, default: 0]
            ordinals[base] = ordinal + 1
            let key = "\(parentKey)/\(base)#\(ordinal)"

            if !flatten {
                var parts = [AX.displayRole(role: role, subrole: subrole)]
                if let title { parts.append("\"\(clip(title, 120))\"") }
                if let desc, desc != title { parts.append("(\(clip(desc, 120)))") }
                if let value, value != title, value != desc {
                    parts.append("value=\"\(clip(value, options.maxValueLength))\"")
                }
                if let placeholder, value == nil { parts.append("placeholder=\"\(clip(placeholder, 80))\"") }
                if let identifier, identifier != title { parts.append("id=\(clip(identifier, 60))") }
                if let help, help != title, help != desc { parts.append("help=\"\(clip(help, 80))\"") }
                var flags: [String] = []
                if !enabled { flags.append("disabled") }
                if focused { flags.append("focused") }
                if selected { flags.append("selected") }
                var actions: [String] = []
                if !invisible {
                    actions = AX.actions(element)
                    if editableRoles.contains(role), AX.isSettable(element, kAXValueAttribute) { flags.append("editable") }
                }
                if !flags.isEmpty { parts.append("[\(flags.joined(separator: ", "))]") }
                let secondary = actions.filter { !hiddenActions.contains($0) && !$0.hasPrefix("AXScroll") }
                    .map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
                if !secondary.isEmpty { parts.append("actions: \(secondary.joined(separator: ","))") }
                let content = parts.joined(separator: " ")
                let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
                var node = UINode(element: element, key: key, depth: depth, content: content, role: role,
                                  frame: frame, actions: actions)
                node.subrole = subrole
                node.identifier = identifier
                node.title = title
                node.desc = desc
                node.placeholder = placeholder
                node.value = secure ? nil : value
                node.enabled = enabled
                node.focused = focused
                node.editable = flags.contains("editable")
                node.secure = secure
                node.selected = selected
                node.ancestors = context.suffix(3).reversed()
                nodes.append(node)
                if focused { focusedSummary = content }
            }
            let named = !flatten && role != "AXWindow" && (identifier != nil || title != nil || desc != nil)
            if named {
                context.append(AncestorLocator(role: role, identifier: identifier, title: title.map { String($0.prefix(120)) },
                                               description: desc.map { String($0.prefix(120)) }))
            }
            defer { if named { context.removeLast() } }

            // Closed menus are expensive and useless; only descend into menus that are open.
            if role == "AXMenuBarItem" || role == "AXMenuItem", !selected { return }
            let childDepth = flatten ? depth : depth + 1
            var childOrdinals: [String: Int] = [:]
            ancestors.append(element)
            defer { ancestors.removeLast() }
            for child in children where !ancestors.contains(where: { CFEqual($0, child) }) {
                visit(child, depth: childDepth, parentKey: key, ordinals: &childOrdinals)
            }
        }

        var title: String?
        var frame: CGRect?
        var windowID: CGWindowID?
        if let window {
            var ordinals: [String: Int] = [:]
            title = AX.string(AX.attribute(window, kAXTitleAttribute))
            frame = AX.frame(window)
            windowID = AX.windowID(window)
            visit(window, depth: 0, parentKey: "W", ordinals: &ordinals)
        }
        // Sheets/popovers/context menus that live outside the window hierarchy.
        var extraOrdinals: [String: Int] = [:]
        for child in AX.elements(app, kAXChildrenAttribute) {
            let role = AX.string(AX.attribute(child, kAXRoleAttribute))
            if role == "AXMenu" { visit(child, depth: 0, parentKey: "P", ordinals: &extraOrdinals) }
        }
        if options.includeMenuBar, let menuBar = AX.element(app, kAXMenuBarAttribute) {
            var ordinals: [String: Int] = [:]
            visit(menuBar, depth: 0, parentKey: "M", ordinals: &ordinals)
        }

        var selectedText: String?
        if let focused = AX.element(app, kAXFocusedUIElementAttribute),
           let text = AX.string(AX.attribute(focused, kAXSelectedTextAttribute)), !text.isEmpty {
            selectedText = text.count > 2000 ? String(text.prefix(2000)) + "…" : text
        }
        return TreeSnapshot(nodes: nodes, windowTitle: title, windowFrame: frame, windowID: windowID,
                            focusedSummary: focusedSummary, selectedText: selectedText, truncated: truncated)
    }
}
