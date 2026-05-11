import SwiftUI
import SwiftData

struct SessionPickerView: View {
    @Environment(\.colorScheme) private var colorScheme

    let onSelect: (Session) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var layoutManager: LayoutManager
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @State private var searchText = ""
    @State private var selectedSessionId: String?
    @State private var scrollTarget: String?
    @State private var sourceFilter: SessionSourceFilter = .claude
    @FocusState private var isSearchFocused: Bool

    private var filteredSessions: [Session] {
        let sourceSessions = sessions.filter(sourceFilter.contains)
        if searchText.isEmpty { return Array(sourceSessions) }
        return sourceSessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(searchText)
            || (session.gitBranch?.localizedCaseInsensitiveContains(searchText) ?? false)
            || (session.sessionTag?.localizedCaseInsensitiveContains(searchText) ?? false)
            || session.cwd.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Selectable sessions (filtered, excluding already-open ones).
    private var selectableSessions: [Session] {
        let openIds = layoutManager.allPanes().compactMap { $0.sessionId }
        return filteredSessions.filter { session in
            !openIds.contains(where: session.matchesIdentityKey)
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

            SessionSourceScopeBar(selection: $sourceFilter, sessions: sessions)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Session list
            ScrollViewReader { proxy in
                List(selection: $selectedSessionId) {
                    let openSessionIds = layoutManager.allPanes().compactMap { $0.sessionId }
                    ForEach(filteredSessions, id: \.identityKey) { session in
                        let alreadyOpen = openSessionIds.contains(where: session.matchesIdentityKey)
                        SessionRow(session: session, isSelected: session.identityKey == selectedSessionId && !alreadyOpen)
                            .tag(session.identityKey)
                            .id(session.identityKey)
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                selectedSessionId == session.identityKey && !alreadyOpen
                                    ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.sessionLedgerSidebarSelection(for: colorScheme))
                                        .padding(.horizontal, 4)
                                    : nil
                            )
                            .opacity(alreadyOpen ? 0.35 : 1)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                guard !alreadyOpen, hovering else { return }
                                selectedSessionId = session.identityKey
                            }
                            .onTapGesture {
                                guard !alreadyOpen else { return }
                                onSelect(session)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    scrollTarget = nil
                    proxy.scrollTo(target)
                }
            }
        }
        .frame(width: 420, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            selectedSessionId = selectableSessions.first?.identityKey
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, _ in
            if selectedSessionId == nil || !filteredSessions.contains(where: { session in
                selectedSessionId.map(session.matchesIdentityKey) ?? false
            }) {
                selectedSessionId = selectableSessions.first?.identityKey
            }
        }
        .onChange(of: sourceFilter) { _, _ in
            selectedSessionId = selectableSessions.first?.identityKey
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
        let list = selectableSessions
        guard !list.isEmpty else { return }
        guard let currentId = selectedSessionId,
              let idx = list.firstIndex(where: { $0.matchesIdentityKey(currentId) }) else {
            selectedSessionId = list.first?.identityKey
            return
        }
        let next = idx + offset
        guard next >= 0, next < list.count else { return }
        selectedSessionId = list[next].identityKey
        scrollTarget = list[next].identityKey
    }

    private func confirmSelection() {
        guard let id = selectedSessionId,
              let session = selectableSessions.first(where: { $0.matchesIdentityKey(id) }) else { return }
        onSelect(session)
    }
}
