import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @Binding var selectedProject: Project?
    @Binding var selectedSession: Session?
    @Environment(\.modelContext) private var modelContext

    @State private var selectedSessions: Set<Session> = []
    @State private var showBulkDeleteConfirm = false
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // ツールバー
            if !selectedSessions.isEmpty {
                HStack {
                    Text("\(selectedSessions.count)件選択中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        if skipDeleteConfirmation {
                            deleteSessions(selectedSessions)
                        } else {
                            showBulkDeleteConfirm = true
                        }
                    } label: {
                        Label("削除", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }

            List(selection: $selectedSessions) {
                ForEach(sessions) { session in
                    SessionRow(session: session, skipDeleteConfirmation: $skipDeleteConfirmation)
                        .tag(session)
                }
            }
            .listStyle(.sidebar)
        }
        .confirmationDialog("セッションを削除", isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                deleteSessions(selectedSessions)
            }
            Button("削除（今後確認しない）", role: .destructive) {
                skipDeleteConfirmation = true
                deleteSessions(selectedSessions)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(selectedSessions.count)件のセッションを削除しますか？JSONLファイルも削除されます。")
        }
        .onChange(of: selectedSessions) { _, newValue in
            // 単一選択時は従来のselectedSessionも更新
            if newValue.count == 1 {
                selectedSession = newValue.first
            }
        }
    }

    private func deleteSessions(_ sessions: Set<Session>) {
        for session in sessions {
            if let fileURL = session.jsonlFileURL {
                try? FileManager.default.removeItem(at: fileURL)
                let backupURL = fileURL.deletingPathExtension().appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backupURL)
            }
            modelContext.delete(session)
        }
        try? modelContext.save()
        selectedSessions.removeAll()
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @Bindable var session: Session
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var layoutManager: LayoutManager
    @Binding var skipDeleteConfirmation: Bool
    @State private var isEditing = false
    @State private var editingName = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // タイトル
            if isEditing {
                TextField("セッション名", text: $editingName, onCommit: {
                    saveSessionName()
                })
                .textFieldStyle(.plain)
                .font(.subheadline)
                .fontWeight(.medium)
                .onExitCommand {
                    isEditing = false
                }
            } else {
                Text(sessionTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

            // メタ情報
            HStack(spacing: 6) {
                // やり取り回数（ユーザーの指示回数）
                HStack(spacing: 3) {
                    Image(systemName: "message")
                        .font(.caption2)
                    Text("\(turnCount)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)

                // ブランチ
                if let branch = session.gitBranch {
                    Text("•")
                        .foregroundStyle(.quaternary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                        Text(branch)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                // 最後のメッセージの日時
                Text(formattedDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button {
                layoutManager.resumeSession(session.sessionId, cwd: session.cwd)
            } label: {
                Label("セッション再開", systemImage: "play.circle")
            }

            Button {
                editingName = session.slug ?? ""
                isEditing = true
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                if skipDeleteConfirmation {
                    deleteSession()
                } else {
                    showDeleteConfirm = true
                }
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
        .confirmationDialog("セッションを削除", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                deleteSession()
            }
            Button("削除（今後確認しない）", role: .destructive) {
                skipDeleteConfirmation = true
                deleteSession()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このセッションを削除しますか？JSONLファイルも削除されます。")
        }
    }

    private func saveSessionName() {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            session.slug = trimmed
            session.isSlugManual = true
        }
        isEditing = false
    }

    private func deleteSession() {
        // JSONLファイルを削除
        if let fileURL = session.jsonlFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            // バックアップも削除
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
        }

        // SwiftDataから削除（メッセージはcascade削除される）
        modelContext.delete(session)
        try? modelContext.save()
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter.string(from: session.updatedAt)
    }

    // ユーザーの指示回数（キャッシュを使用）
    private var turnCount: Int {
        session.cachedTurnCount
    }

    private var sessionTitle: String {
        if let slug = session.slug {
            return formatSlug(slug)
        }
        // キャッシュされたタイトルを使用
        if let cachedTitle = session.cachedTitle {
            return cachedTitle
        }
        // フォールバック: 日時を表示
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: session.startedAt)
    }

    private func formatSlug(_ slug: String) -> String {
        // reactive-prancing-bird -> Reactive Prancing Bird
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

#Preview {
    ProjectListView(selectedProject: .constant(nil), selectedSession: .constant(nil))
        .modelContainer(for: [Project.self, Session.self, Message.self], inMemory: true)
}
