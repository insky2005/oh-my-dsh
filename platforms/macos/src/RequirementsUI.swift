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
    var content: String
    var attempted: Bool

    // L10n keys (the L10n lint sees these as literals).
    var headingKey: String { "requirements.formTitle" }
    var submitKey: String { "requirements.create" }
    var infoKey: String { "requirements.newInfo" }
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

    static func build(content: String = "") -> RequirementComposerModel {
        RequirementComposerModel(content: content, attempted: false)
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
                Section(headingKey: "requirements.help.panel.heading",
                        lineKeys: ["requirements.help.panel.body"]),
                Section(headingKey: "requirements.help.agent.heading",
                        lineKeys: ["requirements.help.agent.body"]),
                Section(headingKey: "requirements.help.breakdown.heading",
                        lineKeys: ["requirements.help.breakdown.body"])
            ])
    }
}
