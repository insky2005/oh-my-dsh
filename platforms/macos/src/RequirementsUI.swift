//
//  RequirementsUI.swift — pure view models for the Requirements Pool panel.
//
//  Kept free of AppKit so the composer's parsing and the help spec can be asserted
//  headlessly (tests/requirements-panel/model-tests.swift).
//

import Foundation

/// The requirements composer's ONE box: the first line is the requirement's title,
/// the lines after it are the 诉求 (a single line is both — RequirementsCore
/// already falls back to the title when the body is empty).
struct RequirementComposerModel: Equatable {

    enum Mode: Equatable {
        case create
        case edit(id: String)

        var isCreate: Bool { self == .create }
        var requirementID: String? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    var content: String
    var attempted: Bool
    var mode: Mode = .create

    // L10n keys (the L10n lint sees these as literals).
    var headingKey: String { mode.isCreate ? "requirements.formTitle" : "requirements.editTitle" }
    var submitKey: String { mode.isCreate ? "requirements.create" : "requirements.save" }
    /// 创建模式多一个「创建并细化」按钮（建卡后起一条细化会话）；编辑模式没有。
    var refineKey: String { "requirements.createAndRefine" }
    var showsRefineButton: Bool { mode.isCreate }
    var infoKey: String { mode.isCreate ? "requirements.newInfo" : "requirements.editInfo" }
    var contentCaptionKey: String { "requirements.newContent" }
    var placeholderKey: String { "requirements.newContentHint" }

    /// What would be created right now.
    var title: String { draft.title }
    var body: String { draft.body }
    var canSubmit: Bool { !title.isEmpty }
    /// Shown only after an incomplete submit attempt.
    var problemKey: String? { attempted && title.isEmpty ? "requirements.newProblem" : nil }
    var isPristine: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var draft: (title: String, body: String) {
        let lines = content.components(separatedBy: .newlines)
        let title = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, rest.isEmpty ? title : rest)
    }

    func typed(content: String) -> RequirementComposerModel {
        var copy = self
        copy.content = content
        return copy
    }

    func attemptedSubmit() -> RequirementComposerModel {
        var copy = self
        copy.attempted = true
        return copy
    }

    static func build(mode: Mode = .create, content: String = "") -> RequirementComposerModel {
        RequirementComposerModel(content: content, attempted: false, mode: mode)
    }

    /// The composer for editing an existing card: title + 诉求 back in the one box.
    static func edit(_ card: RequirementCard) -> RequirementComposerModel {
        let statement = card.statement
        let content = (statement.isEmpty || statement == card.title) ? card.title : card.title + "\n" + statement
        return RequirementComposerModel(content: content, attempted: false, mode: .edit(id: card.id))
    }
}

/// The 使用说明 content as L10n keys. Rendered by the shared help text view / help
/// drawer (TaskInlineForms.swift); kept independent of the tasks help model so the
/// keys stay requirements.*.
struct RequirementsHelpSpec: Equatable {
    struct Section: Equatable {
        var headingKey: String
        var lineKeys: [String]
    }
    var titleKey: String
    var introKey: String
    var sections: [Section]

    static func build() -> RequirementsHelpSpec {
        RequirementsHelpSpec(
            titleKey: "requirements.help.title",
            introKey: "requirements.help.intro",
            sections: [
                Section(headingKey: "requirements.help.create.heading",
                        lineKeys: ["requirements.help.create.panel",
                                   "requirements.help.create.chat"]),
                Section(headingKey: "requirements.help.breakdown.heading",
                        lineKeys: ["requirements.help.breakdown.panel",
                                   "requirements.help.breakdown.chat"])
            ])
    }
}

/// The 驳回 reason drawer's pure model: ONE required text area. A rejection must say
/// why — the reason is carried into the requirement's conversation prompt so the
/// agent revises the breakdown instead of guessing.
struct RejectReasonModel {

    var content: String = ""
    var attempted = false

    let headingKey = "requirements.reject.title"
    let infoKey = "requirements.reject.info"
    let contentCaptionKey = "requirements.reject.content"
    let placeholderKey = "requirements.reject.placeholder"
    let submitKey = "requirements.reject.submit"

    static func build() -> RejectReasonModel { RejectReasonModel() }

    var reason: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { !reason.isEmpty }
    var problemKey: String? { attempted && !canSubmit ? "requirements.reject.problem" : nil }

    func typed(content: String) -> RejectReasonModel {
        var model = self
        model.content = content
        return model
    }

    func attemptedSubmit() -> RejectReasonModel {
        var model = self
        model.attempted = true
        return model
    }
}

/// One rendered row of a requirement's 已拆解事项 list. CONTENT (id / title /
/// boundary / deps) comes from the REQ card's confirmed table; STATUS (stage /
/// outcome) comes from the WS card — see
/// docs/design/panels/requirements-breakdown-standard-design.md (C2 / C3).
struct WorkstreamDisplay: Equatable {
    /// 标识: nil for a candidate row that has no workstream card.
    var id: String?
    var title: String
    var boundary: String
    var dependsOn: [String]
    var stage: String?
    var outcome: String?
    var path: String?
    /// The REQ table lists an id whose WS card is absent.
    var missingCard: Bool = false
    /// The WS card exists but the REQ table does not list it.
    var notInPlan: Bool = false

    /// Merge the two authorities. REQ rows lead (and keep their order); WS children
    /// that the table misses are appended and flagged. An empty table (legacy card
    /// that was never parsed) falls back to the plain WS children without flags.
    static func merged(confirmed: [ConfirmedItem], children: [WorkstreamSummary]) -> [WorkstreamDisplay] {
        if confirmed.isEmpty {
            return children.map { child in
                WorkstreamDisplay(id: child.id, title: child.title, boundary: "", dependsOn: [],
                                  stage: child.stage, outcome: child.outcome, path: child.path)
            }
        }
        var byId: [String: WorkstreamSummary] = [:]
        for child in children where byId[child.id] == nil { byId[child.id] = child }
        var used = Set<String>()
        var out: [WorkstreamDisplay] = []
        for row in confirmed {
            var display = WorkstreamDisplay(id: row.id, title: row.title, boundary: row.boundary,
                                            dependsOn: row.dependsOn, stage: nil, outcome: nil, path: nil)
            if let id = row.id {
                if let child = byId[id] {
                    used.insert(id)
                    display.stage = child.stage
                    display.outcome = child.outcome
                    display.path = child.path
                    if display.title.isEmpty { display.title = child.title }
                } else {
                    display.missingCard = true
                }
            }
            out.append(display)
        }
        for child in children where !used.contains(child.id) {
            out.append(WorkstreamDisplay(id: child.id, title: child.title, boundary: "", dependsOn: [],
                                         stage: child.stage, outcome: child.outcome, path: child.path,
                                         missingCard: false, notInPlan: true))
        }
        return out
    }
}
