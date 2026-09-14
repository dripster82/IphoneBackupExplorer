import SwiftUI
import AppKit

struct MessagesListView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if model.isLoadingData && model.conversations.isEmpty {
                ProgressView("Reading Messages…")
            } else if let err = model.dataError {
                ContentUnavailableView("Can't Read Messages", systemImage: "bubble.left.and.exclamationmark.bubble.right", description: Text(err))
            } else if model.conversations.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "bubble.left.and.bubble.right", description: Text("This backup has no SMS/iMessage history."))
            } else {
                List(selection: $model.selectedConversationID) {
                    ForEach(model.filteredConversations) { convo in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(convo.name).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                if let d = convo.lastDate {
                                    Text(d, format: .dateTime.day().month(.abbreviated).year()).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(convo.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(convo.messages.count) messages").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .tag(convo.id)
                    }
                }
            }
        }
        .navigationTitle("Messages")
        .navigationSubtitle(model.conversations.isEmpty ? "" : "\(model.conversations.count) conversations")
        .searchable(text: $model.messageSearch, placement: .toolbar, prompt: "Search messages")
    }
}

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let convo = model.selectedConversation {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(convo.messages) { msg in
                            MessageBubble(message: msg)
                        }
                    }
                    .padding(12)
                }
                Divider()
                HStack {
                    if !convo.handles.isEmpty {
                        Text(convo.handles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.exportConversation(convo) } label: { Label("Export Transcript", systemImage: "square.and.arrow.up") }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .navigationTitle(convo.name)
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject var model: AppModel
    let message: SMSMessage
    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                ForEach(message.attachments, id: \.self) { att in
                    AttachmentView(attachment: att)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isFromMe ? Color.accentColor : Color.secondary.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(message.isFromMe ? .white : .primary)
                } else if message.attachments.isEmpty {
                    Text("(no text — unsupported message)").font(.caption).italic().foregroundStyle(.tertiary)
                }
                if let d = message.date {
                    Text(d, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !message.isFromMe { Spacer(minLength: 40) }
        }
    }
}

private struct AttachmentView: View {
    @EnvironmentObject var model: AppModel
    let attachment: MessageAttachment
    @State private var image: NSImage?
    @State private var url: URL?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { if let url { QuickLookPanelController.shared.show(url) } }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: missing ? "questionmark.square.dashed" : (attachment.isImage ? "photo" : "paperclip"))
                    Text(attachment.displayName).lineLimit(1)
                    if url != nil {
                        Button { export() } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(missing ? .secondary : .primary)
            }
        }
        .task(id: attachment) { await load() }
    }

    private func load() async {
        image = nil; url = nil; missing = false
        guard let session = model.session,
              let file = model.file(pathSuffix: attachment.pathSuffix) else { missing = true; return }
        let u = try? await Task.detached(priority: .userInitiated) { try session.materialise(file) }.value
        url = u
        if attachment.isImage, let u {
            image = await Task.detached { NSImage(contentsOf: u) }.value
        }
    }

    private func export() {
        guard let file = model.file(pathSuffix: attachment.pathSuffix) else { return }
        model.exportFileWithPanel(file, suggestedName: attachment.displayName)
    }
}
