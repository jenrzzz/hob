import SwiftUI

/// One request at the sentinel that policy, or the reviewer, left for a
/// person: allow it (hob runs it as the agent) or deny it.
struct RequestView: View {
    let id: String

    @Environment(Session.self) private var session
    @State private var request: SentinelRequest?
    @State private var loadError: String?
    @State private var comment = ""
    @State private var submitting = false
    @State private var submitError: String?

    var body: some View {
        Group {
            if let request {
                form(request)
            } else if let loadError {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
        .refreshable { await load() }
        .alert("Not decided", isPresented: Binding(get: { submitError != nil }, set: { if !$0 { submitError = nil } })) {
            Button("OK") {}
        } message: {
            Text(submitError ?? "")
        }
    }

    private func form(_ request: SentinelRequest) -> some View {
        Form {
            Section("Asks for") {
                HStack {
                    Text(request.agent).font(.headline)
                    Spacer()
                    StatusBadge(status: request.status)
                }
                Text(request.capability).font(.system(.body, design: .monospaced))
                Field("Reason", request.reason)
                JSONBlock("Arguments", request.arguments)
                Field("Asked", request.createdAt.formatted(date: .abbreviated, time: .shortened) + " · realm " + request.realm)
                Field("On mission", request.onMission)
            }

            Section(request.decidedBy == "human" ? "Decision" : "Verdict so far") {
                Field("Decision", request.decision)
                Field("Rationale", request.rationale)
                Field("Decided by", [request.decidedBy, request.decider].compactMap { $0 }.joined(separator: " · "))
            }

            if request.result != nil || request.error != nil || request.mission != nil {
                Section("Outcome") {
                    JSONBlock("Result", request.result)
                    Field("Mission", request.mission)
                    if let error = request.error {
                        Field("Error", error).foregroundStyle(.red)
                    }
                }
            }

            if request.needsPerson {
                Section("Your decision") {
                    CommentField(text: $comment)
                    HStack {
                        Button(role: .destructive) { Task { await submit("deny") } } label: {
                            HStack { Spacer(); Text("Deny").bold(); Spacer() }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("deny")
                        Button { Task { await submit("allow") } } label: {
                            HStack { Spacer(); Text("Allow").bold(); Spacer() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("allow")
                    }
                    .disabled(submitting)
                }
            }
        }
    }

    private func load() async {
        do {
            request = try await session.request(id)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func submit(_ decision: String) async {
        submitting = true
        defer { submitting = false }
        do {
            let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            request = try await session.decide(request: id, RequestDecision(decision: decision, rationale: trimmed.isEmpty ? nil : trimmed))
            comment = ""
        } catch {
            submitError = error.localizedDescription
        }
    }
}
