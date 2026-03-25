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
            // Toolbar
            if !selectedSessions.isEmpty {
                HStack {
                    Text(String(format: L("sidebar.selection.count"), selectedSessions.count))
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
                        Label(L("common.delete"), systemImage: "trash")
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
        .confirmationDialog(L("sidebar.deleteSession.title"), isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
            Button(L("common.delete"), role: .destructive) {
                deleteSessions(selectedSessions)
            }
            Button(L("sidebar.deleteAndDontAsk"), role: .destructive) {
                skipDeleteConfirmation = true
                deleteSessions(selectedSessions)
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("sidebar.deleteMany.confirm"), selectedSessions.count))
        }
        .onChange(of: selectedSessions) { _, newValue in
            // Preserve the previous single-selection behavior.
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
    @Binding var skipDeleteConfirmation: Bool
    @State private var isEditing = false
    @State private var editingName = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            if isEditing {
                TextField(L("sidebar.sessionName.placeholder"), text: $editingName, onCommit: {
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

            // Metadata
            HStack(spacing: 6) {
                // User turn count
                HStack(spacing: 3) {
                    Image(systemName: "message")
                        .font(.caption2)
                    Text("\(turnCount)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)

                // Branch
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

                // Last message timestamp
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
                editingName = session.slug ?? ""
                isEditing = true
            } label: {
                Label(L("sidebar.rename"), systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                if skipDeleteConfirmation {
                    deleteSession()
                } else {
                    showDeleteConfirm = true
                }
            } label: {
                Label(L("common.delete"), systemImage: "trash")
            }
        }
        .confirmationDialog(L("sidebar.deleteSession.title"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L("common.delete"), role: .destructive) {
                deleteSession()
            }
            Button(L("sidebar.deleteAndDontAsk"), role: .destructive) {
                skipDeleteConfirmation = true
                deleteSession()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("sidebar.deleteSession.confirmSingle"))
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
        // Delete the JSONL file.
        if let fileURL = session.jsonlFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            // Delete the backup file too.
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
        }

        // Delete from SwiftData. Messages are removed by cascade.
        modelContext.delete(session)
        try? modelContext.save()
    }

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    private var formattedDate: String {
        Self.sessionDateFormatter.string(from: session.updatedAt)
    }

    // Cached user turn count.
    private var turnCount: Int {
        session.cachedTurnCount
    }

    private var sessionTitle: String {
        if let slug = session.slug {
            return formatSlug(slug)
        }
        if let cachedTitle = session.cachedTitle {
            return cachedTitle
        }
        return session.displayTitle
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
