import SwiftUI
import AppKit

/// Claude Code conversation view with streaming responses.
struct ClaudeView: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                ClaudeIcon(size: 20)

                Text("Claude Code")
                    .font(.system(size: 16, weight: .medium))

                Spacer()

                if viewModel.claudeIsStreaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Thinking...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().opacity(0.5)

            // Conversation
            if viewModel.claudeMessages.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    ClaudeIcon(size: 48)
                    Text("Ask Anything")
                        .font(.system(size: 18, weight: .medium))
                    Text("Type a question and press Enter")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 350)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(viewModel.claudeMessages) { message in
                                MessageBubble(message: message, isStreaming: viewModel.claudeIsStreaming && message.id == viewModel.claudeMessages.last?.id)
                                    .id(message.id)
                            }
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: viewModel.claudeMessages.last?.text) { _, _ in
                        if let lastId = viewModel.claudeMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().opacity(0.5)

            // Input bar
            if !viewModel.claudePendingAttachments.isEmpty
                || viewModel.claudeAttachmentError != nil
                || viewModel.claudeAttachmentIsImporting {
                ClaudeAttachmentComposer(
                    attachments: viewModel.claudePendingAttachments,
                    error: viewModel.claudeAttachmentError,
                    isImporting: viewModel.claudeAttachmentIsImporting,
                    onRemove: viewModel.removePendingClaudeAttachment
                )
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            HStack(spacing: 12) {
                TextField("Follow up...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isInputFocused)
                    .onAppear { isInputFocused = true }
                    .disabled(viewModel.claudeIsStreaming)

                if viewModel.claudeCanRetryLastRequest {
                    Button(action: { viewModel.claudeRetryLastRequest() }) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                if viewModel.claudeIsStreaming {
                    Button(action: { viewModel.claudeCancel() }) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            // Footer
            Divider().opacity(0.3)
            HStack {
                HStack(spacing: 6) {
                    ClaudeIcon(size: 14)
                    Text("Claude Code")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 12) {
                    if !viewModel.claudeMessages.isEmpty && !viewModel.claudeIsStreaming {
                        KeyHint(keys: ["⌘", "↵"], label: "replace")
                        KeyHint(keys: ["⌘", "C"], label: "copy")
                    }
                    if !viewModel.claudeIsStreaming {
                        KeyHint(keys: ["⌘", "V"], label: "attach image")
                        KeyHint(keys: ["↵"], label: "send")
                    }
                    KeyHint(keys: ["esc"], label: "back")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 680)
        .frame(minHeight: 500)
    }
}

/// A single message bubble in the conversation.
struct MessageBubble: View {
    let message: ClaudeMessage
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 60)
                // User message — right aligned
                VStack(alignment: .leading, spacing: 8) {
                    if !message.attachments.isEmpty {
                        ClaudeAttachmentGallery(attachments: message.attachments)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                // Assistant message — left aligned with icon
                VStack(alignment: .leading, spacing: 0) {
                    if message.text.isEmpty && isStreaming {
                        // Thinking indicator
                        HStack(spacing: 8) {
                            ThinkingDots()
                            Text("Thinking...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                    } else {
                        Text(message.text)
                            .font(.system(size: 13))
                            .padding(10)
                            .textSelection(.enabled)
                    }

                    if isStreaming && !message.text.isEmpty {
                        // Streaming cursor
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .opacity(0.8)
                        }
                        .padding(.leading, 10)
                        .padding(.bottom, 4)
                    }
                }
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Spacer(minLength: 60)
            }
        }
    }
}

struct ClaudeAttachmentComposer: View {
    let attachments: [ClaudeImageAttachment]
    let error: String?
    let isImporting: Bool
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isImporting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing image attachment…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                ClaudeAttachmentImageView(attachment: attachment)
                                    .frame(width: 36, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(attachment.displayName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .frame(maxWidth: 110)
                                Button {
                                    onRemove(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove attachment")
                            }
                            .padding(5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

}

private struct ClaudeAttachmentImageView: View {
    let attachment: ClaudeImageAttachment
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.05)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: attachment.id) {
            let url = attachment.url
            let data = await Task.detached(priority: .utility) {
                ClaudeImageAttachmentStore.thumbnailData(for: url)
            }.value
            guard !Task.isCancelled, let data else { return }
            image = NSImage(data: data)
        }
    }
}

struct ClaudeAttachmentGallery: View {
    let attachments: [ClaudeImageAttachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                ClaudeAttachmentImageView(attachment: attachment)
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .help(attachment.displayName)
            }
        }
    }
}

/// Animated thinking dots using SwiftUI animation.
struct ThinkingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
