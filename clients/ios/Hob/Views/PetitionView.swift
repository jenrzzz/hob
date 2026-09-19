import SwiftUI

/// One petition: what the agent wants, what the steward thought, and the
/// person's decision — grant an existing capability at an effect, build a
/// new one through the forge, or deny.
struct PetitionView: View {
    let id: String

    @Environment(Session.self) private var session
    @State private var petition: Petition?
    @State private var loadError: String?
    @State private var decision = "grant"
    @State private var capability = ""
    @State private var effect = "review"
    @State private var comment = ""
    @State private var submitting = false
    @State private var submitError: String?

    var body: some View {
        Group {
            if let petition {
                form(petition)
            } else if let loadError {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Petition")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
        .refreshable { await load() }
        .alert("Not decided", isPresented: Binding(get: { submitError != nil }, set: { if !$0 { submitError = nil } })) {
            Button("OK") {}
        } message: {
            Text(submitError ?? "")
        }
    }

    private func form(_ petition: Petition) -> some View {
        Form {
            Section {
                HStack {
                    Text(petition.agent).font(.headline)
                    Spacer()
                    StatusBadge(status: petition.status)
                }
                Text(petition.want)
                Field("Reason", petition.reason)
                Field("Asked", petition.createdAt.formatted(date: .abbreviated, time: .shortened) + " · realm " + petition.realm)
                Field("On mission", petition.onMission)
            } header: {
                Text("Wants")
            }

            Section("Capability") {
                Field("Name", petition.capability)
                Field("Effect", petition.effect)
                JSONBlock("Example arguments", petition.arguments)
            }

            Section(petition.decidedBy == "human" ? "Decision" : "Steward") {
                Field("Action", [petition.action, petition.recommendation.map { "(recommended \($0))" }].compactMap { $0 }.joined(separator: " "))
                Field("Rationale", petition.rationale)
                Field("Decided by", [petition.decidedBy, petition.decider].compactMap { $0 }.joined(separator: " · "))
            }

            if let spec = petition.spec, !spec.isEmpty {
                Section("Spec") {
                    Field("Description", spec["description"]?.stringValue)
                    Field("Kind · realm", [spec["kind"]?.stringValue, spec["realm"]?.stringValue].compactMap { $0 }.joined(separator: " · "))
                    Field("Behaviour", spec["behaviour"]?.stringValue)
                    Field("Acceptance", spec["acceptance"]?.stringValue)
                    Field("Notes", spec["notes"]?.stringValue)
                    JSONBlock("Input schema", spec["input_schema"] ?? spec["input_schema_json"])
                }
            }

            if petition.mission != nil || petition.pullRequest != nil || petition.error != nil || petition.policy != nil {
                Section("Outcome") {
                    Field("Build mission", petition.mission)
                    if let pr = petition.pullRequest, let url = URL(string: pr) {
                        Link(destination: url) { Label(pr, systemImage: "arrow.up.right.square") }
                    }
                    Field("Policy", petition.policy.map { "rule #\($0)" })
                    if let error = petition.error {
                        Field("Error", error).foregroundStyle(.red)
                    }
                }
            }

            if petition.needsPerson {
                Section("Your decision") {
                    Picker("Decision", selection: $decision) {
                        Text("Grant").tag("grant")
                        Text("Build").tag("build")
                        Text("Deny").tag("deny")
                    }
                    .pickerStyle(.segmented)
                    if decision == "grant" {
                        TextField("Capability", text: $capability)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Effect", selection: $effect) {
                            Text("allow").tag("allow")
                            Text("review").tag("review")
                            Text("confirm").tag("confirm")
                        }
                    }
                    if decision == "build" {
                        Text(petition.spec?.isEmpty == false ? "The forge builds the steward's spec above and opens a pull request." : "There is no spec to build from; the steward drafts one when it recommends a build.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    CommentField(text: $comment)
                    Button(role: decision == "deny" ? .destructive : nil) {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if submitting { ProgressView() } else { Text(buttonTitle).bold() }
                            Spacer()
                        }
                    }
                    .disabled(submitting || (decision == "grant" && capability.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("decide")
                }
            }
        }
    }

    private var buttonTitle: String {
        switch decision {
        case "grant": return "Grant \(capability.isEmpty ? "" : capability) at \(effect)"
        case "build": return "Build it"
        default: return "Deny"
        }
    }

    private func load() async {
        do {
            let row = try await session.petition(id)
            petition = row
            loadError = nil
            if capability.isEmpty { capability = row.capability ?? "" }
            if let recommended = row.effect { effect = recommended }
            if row.recommendation == "build" || (row.action == "build" && row.status == "failed") { decision = "build" }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        do {
            let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            petition = try await session.decide(petition: id, PetitionDecision(
                decision: decision,
                capability: decision == "grant" ? capability.trimmingCharacters(in: .whitespaces) : nil,
                effect: decision == "grant" ? effect : nil,
                rationale: trimmed.isEmpty ? nil : trimmed
            ))
            comment = ""
        } catch {
            submitError = error.localizedDescription
        }
    }
}
