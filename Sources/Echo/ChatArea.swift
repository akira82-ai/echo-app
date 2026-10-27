import SwiftUI

struct ChatArea: View {
    @ObservedObject var state: ChatState
    var accent: Color = .secondary
    var hasReference = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if state.busy {
                    ChatActivityLabel(text: L10n.text(state.activityKey))
                } else {
                    Text(L10n.text("chat.title"))
                        .font(.caption).foregroundStyle(accent)
                }
                if !state.answer.isEmpty {
                    Text(.init(state.answer)).font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let key = state.errorKey {
                    Text(L10n.text(key)).foregroundStyle(.secondary)
                } else if !state.busy && state.answer.isEmpty {
                    Text(L10n.text(hasReference ? "chat.reference.instruction" : "chat.empty"))
                    Text(L10n.text(hasReference ? "chat.reference.help" : "chat.privacy")).font(.caption).foregroundStyle(.secondary)
                }
                if state.answer.isEmpty && !state.busy {
                    Button(L10n.text("chat.settings")) {
                        QuickPanelController.shared.hide()
                        (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
                    }.buttonStyle(.link)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct ChatActivityLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let rotation = time.truncatingRemainder(dividingBy: 1.8) / 1.8
            let shimmer = time.truncatingRemainder(dividingBy: 3) / 3
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    Circle().trim(from: 0, to: 0.35)
                        .stroke(AngularGradient(colors: [.secondary.opacity(0.1), Color(red: 0.36, green: 0.58, blue: 0.62)], center: .center), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .rotationEffect(.degrees(rotation * 360))
                }.frame(width: 16, height: 16).accessibilityHidden(true)
                Text(text)
                    .font(.caption).foregroundStyle(.secondary)
                    .overlay {
                        if !reduceMotion {
                            GeometryReader { geometry in
                                LinearGradient(colors: [.clear, .primary.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: geometry.size.width * 0.6)
                                    .offset(x: geometry.size.width * (shimmer * 1.8 - 0.6))
                            }.mask(Text(text).font(.caption))
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
