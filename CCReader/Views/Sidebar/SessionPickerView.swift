import SwiftUI
import SwiftData

struct SessionPickerView: View {
    let onSelect: (Session) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var layoutManager: LayoutManager
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @State private var searchText = ""
    @State private var selectedSessionId: String?
    /// Only scroll-to when navigating via keyboard; hover just highlights.
    @State private var needsKeyboardScroll = false
    @FocusState private var isSearchFocused: Bool

    private var filteredSessions: [Session] {
        if searchText.isEmpty { return Array(sessions) }
        return sessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(searchText)
            || (session.gitBranch?.localizedCaseInsensitiveContains(searchText) ?? false)
            || (session.sessionTag?.localizedCaseInsensitiveContains(searchText) ?? false)
            || session.cwd.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("picker.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { confirmSelection() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Session list
            ScrollViewReader { proxy in
                ScrollView {
                    let openSessionIds = Set(layoutManager.allPanes().compactMap { $0.sessionId })
                    LazyVStack(spacing: 2) {
                        ForEach(filteredSessions, id: \.sessionId) { session in
                            let alreadyOpen = openSessionIds.contains(session.sessionId)
                            let isSelected = session.sessionId == selectedSessionId
                            SessionRow(session: session, isSelected: isSelected)
                                .id(session.sessionId)
                                .contentShape(Rectangle())
                                .opacity(alreadyOpen ? 0.35 : 1)
                                .onTapGesture {
                                    guard !alreadyOpen else { return }
                                    onSelect(session)
                                }
                                .onHover { hovering in
                                    guard !alreadyOpen, hovering else { return }
                                    selectedSessionId = session.sessionId
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedSessionId) { _, newId in
                    guard needsKeyboardScroll, let newId else {
                        needsKeyboardScroll = false
                        return
                    }
                    needsKeyboardScroll = false
                    withAnimation {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            selectedSessionId = filteredSessions.first?.sessionId
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, _ in
            if selectedSessionId == nil || !filteredSessions.contains(where: { $0.sessionId == selectedSessionId }) {
                selectedSessionId = filteredSessions.first?.sessionId
            }
        }
        .onKeyPress(.upArrow) {
            navigate(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigate(offset: 1)
            return .handled
        }
        .onKeyPress(.return) {
            confirmSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }

    private func navigate(offset: Int) {
        let list = filteredSessions
        guard !list.isEmpty else { return }
        let current = selectedSessionId.flatMap { id in list.firstIndex(where: { $0.sessionId == id }) } ?? 0
        let next = max(0, min(current + offset, list.count - 1))
        selectedSessionId = list[next].sessionId
        needsKeyboardScroll = true
    }

    private func confirmSelection() {
        let list = filteredSessions
        guard let id = selectedSessionId,
              let session = list.first(where: { $0.sessionId == id }) else { return }
        guard !layoutManager.allPanes().contains(where: { $0.sessionId == session.sessionId }) else { return }
        onSelect(session)
    }
}
