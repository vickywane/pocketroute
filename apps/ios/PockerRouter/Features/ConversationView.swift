import SwiftUI

/// The re-routing thread: the passenger's report, route options and follow-ups.
struct ConversationView: View {
    let graph: NetworkGraph
    @Binding var voiceTarget: VoiceTarget?
    @Environment(RerouteSession.self) private var session
    @State private var followUp = ""
    @FocusState private var composing: Bool
    @State private var expandedEntries: Set<UUID> = []
    @State private var picker: StationPickerView.Mode?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if session.thread.isEmpty { emptyState }
                        ForEach(session.thread) { entry in
                            entryView(entry, isLatest: entry.id == session.thread.last?.id).id(entry.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: session.thread.count) { _, _ in
                    if let last = session.thread.last?.id { withAnimation { proxy.scrollTo(last, anchor: .top) } }
                }
            }
            quickReplies
        }
        .background(Theme.canvas)
        .sheet(item: $picker, onDismiss: { session.pickedFromList(graph: graph) }) { mode in
            StationPickerView(graph: graph, mode: mode)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: ThreadEntry, isLatest: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Bubble(text: entry.userText, isUser: true)
            if entry.dictated {
                Label("Dictated · on this iPhone", systemImage: "mic").font(Typography.footnote).foregroundStyle(Theme.secondary)
            }
            if !entry.isPending, entry.understoodBy != .tap, !entry.tags.isEmpty || entry.understoodBy != nil {
                UnderstoodRow(tags: entry.tags, by: entry.understoodBy)
            }
        }
        if entry.isPending {
            ThinkingBubble()
        } else {
            AssistantBubble(text: entry.replyText)
        }
        if isLatest, let field = entry.asking, session.awaiting == field {
            choiceList(entry.choices, field: field)
        }
        if isLatest || expandedEntries.contains(entry.id) {
            ForEach(entry.plans) { plan in
                Button { session.start(plan, graph: graph) } label: { RouteCard(plan: plan, graph: graph) }
                    .buttonStyle(.plain)
            }
        } else if !entry.plans.isEmpty {
            Button { expandedEntries.insert(entry.id) } label: {
                HStack {
                    Image(systemName: "chevron.right")
                    Text("\(entry.plans.count) earlier option\(entry.plans.count == 1 ? "" : "s")").font(Typography.subheadMedium)
                    Spacer()
                    Text("Show").font(Typography.caption)
                }
                .foregroundStyle(Theme.accentText).padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    /// Stations offered as answers, then the full list as an escape hatch.
    private func choiceList(_ ids: [String], field: AskField) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let station = graph.stations[id] {
                    Button { session.choose(id, graph: graph) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(station.name).font(Typography.headline).foregroundStyle(Theme.ink)
                                HStack(spacing: 4) {
                                    ForEach(station.lineIds.prefix(4), id: \.self) { LineTag(lineId: $0, name: graph.lineName($0)) }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 64).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < ids.count - 1 { InsetDivider(leading: 16) }
                }
            }
            if !ids.isEmpty { InsetDivider(leading: 16) }
            Button { picker = field == .origin ? .origin : .destination } label: {
                HStack {
                    Image(systemName: "list.bullet")
                    Text(ids.isEmpty ? "Choose a station" : "Another station").font(Typography.headline)
                    Spacer()
                }
                .foregroundStyle(Theme.accentText).padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
        .disabled(session.isThinking)
    }

    private var header: some View {
        TopNavHeader(title: title, leading: { MenuButton() }, trailing: {
            Button { session.tab = 2 } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.ink).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        })
    }

    /// Opened from the Ask AI tab before the form is complete.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask AI", systemImage: "sparkles").font(Typography.caption).foregroundStyle(Theme.accentText)
            Text("Tell me where you are, where you’re going and what happened. For example: “Held at Camden, need Warren Street.”")
                .font(Typography.body).foregroundStyle(Theme.ink)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var title: String {
        guard let request = session.request,
              let origin = graph.stations[request.origin]?.name,
              let destination = graph.stations[request.destination]?.name else { return "Ask AI" }
        return "\(origin) → \(destination)"
    }

    private var quickReplies: some View {
        VStack(spacing: 10) {
            if !session.latestPlans.isEmpty && session.awaiting == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("Train is moving again")
                        chip("Branch isn’t running")
                        chip("Step-free only")
                        chip("I’d rather walk")
                    }
                    .padding(.horizontal, 20)
                }
            }
            // One trailing control: the mic while the field is empty, send once there's text.
            HStack(spacing: 8) {
                TextField(session.awaiting == .origin ? "Type the station you’re at" : (session.awaiting == .destination ? "Type where you’re going" : (session.thread.isEmpty ? "Type what happened" : "Say what’s changed")),
                          text: $followUp)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .font(Typography.body)
                    .padding(.leading, 20)
                composerButton
            }
            .padding(.trailing, 6)
            .frame(height: 56)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(composing ? Theme.accent : Theme.line, lineWidth: composing ? 1.5 : 1))
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .padding(.top, 8)
        .background(Theme.canvas)
    }

    private var hasText: Bool { !followUp.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Outline circle inside the field: mic when empty, send when typing.
    private var composerButton: some View {
        Button {
            if hasText { send() } else { voiceTarget = .followUp }
        } label: {
            Image(systemName: hasText ? "arrow.up" : "mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(session.isThinking ? Theme.secondary : Theme.accentText)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(session.isThinking ? Theme.line : Theme.accent, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(session.isThinking)
        .accessibilityLabel(hasText ? "Send" : "Speak instead")
    }

    private func chip(_ text: String) -> some View {
        Button { Task { await session.followUp(text, graph: graph, isQuickReply: true) } } label: {
            Text(text).font(Typography.callout).foregroundStyle(Theme.accentText)
                .padding(.horizontal, 16).frame(height: 48)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(session.isThinking)
    }

    private func send() {
        let text = followUp
        followUp = ""
        Task { await session.followUp(text, graph: graph) }
    }
}
