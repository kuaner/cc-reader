import SwiftUI
import SwiftData

struct SessionPickerView: View {
    let onSelect: (Session) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var layoutManager: LayoutManager
    @Query(sort: \Session.updatedAt, order: .reverse) private var sessions: [Session]
    @State private var searchText = ""
    @State private var selectedIndex = 0
    /// Only scroll-to when navigating via keyboard; hover just highlights.
    @State private var needsKeyboardScroll = false
    @FocusState private var isSearchFocused: Bool

    private var filteredSessions: [Session] {
        if searchText.isEmpty { return Array(sessions) }
        let query = searchText.lowercased()
        return sessions.filter { session in
            session.displayTitle.lowercased().contains(query)
            || (session.gitBranch?.lowercased().contains(query) ?? false)
            || (session.sessionTag?.lowercased().contains(query) ?? false)
            || session.cwd.lowercased().contains(query)
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
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filteredSessions.enumerated()), id: \.element.sessionId) { index, session in
                            let alreadyOpen = layoutManager.allPanes().contains { $0.sessionId == session.sessionId }
                            SessionRow(session: session, isSelected: index == selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .opacity(alreadyOpen ? 0.35 : 1)
                                .onTapGesture {
                                    guard !alreadyOpen else { return }
                                    onSelect(session)
                                }
                                .onHover { hovering in
                                    guard !alreadyOpen else { return }
                                    if hovering { selectedIndex = index }
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    guard needsKeyboardScroll else {
                        needsKeyboardScroll = false
                        return
                    }
                    needsKeyboardScroll = false
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            selectedIndex = 0
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                needsKeyboardScroll = true
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredSessions.count - 1 {
                needsKeyboardScroll = true
                selectedIndex += 1
            }
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

    private func confirmSelection() {
        let list = filteredSessions
        guard !list.isEmpty, selectedIndex < list.count else { return }
        onSelect(list[selectedIndex])
    }
}
