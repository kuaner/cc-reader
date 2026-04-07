import SwiftUI
import SwiftData

@main
struct CCReaderApp: App {
    let container: ModelContainer

    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
        TabSwitchMonitor.install()
        do {
            let schema = Schema([
                Project.self,
                Session.self,
                Message.self
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(modelContainer: container)
                .modelContainer(container)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L("menu.newTab")) {
                    NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button(L("menu.splitHorizontal")) {
                    LayoutManager.active?.requestSplitFocused(direction: .horizontal)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button(L("menu.splitVertical")) {
                    LayoutManager.active?.requestSplitFocused(direction: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(L("menu.switchSession")) {
                    LayoutManager.active?.requestSwitchSession()
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                Button(L("menu.closePane")) {
                    LayoutManager.active?.closeFocused()
                }
                .keyboardShortcut("w", modifiers: .command)

                Button(L("menu.prevPane")) {
                    LayoutManager.active?.focusPreviousPane()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button(L("menu.nextPane")) {
                    LayoutManager.active?.focusNextPane()
                }
                .keyboardShortcut("]", modifiers: .command)

                Divider()

                Button(L("sidebar.toggle")) {
                    LayoutManager.active?.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                ThemeMenuCommands()
            }

            CommandGroup(replacing: .help) {
                Button(L("menu.github")) {
                    if let url = URL(string: "https://github.com/kuaner/cc-reader") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Theme menu（与 UserDefaults 同步，显示当前选中）

private struct ThemeMenuCommands: View {
    @AppStorage(WebColorTheme.storageKey) private var themeIdRaw: String = WebColorTheme.everforest.rawValue

    private var selectedTheme: Binding<WebColorTheme> {
        Binding(
            get: { WebColorTheme(rawValue: themeIdRaw) ?? .everforest },
            set: { $0.broadcast() }
        )
    }

    var body: some View {
        Menu {
            // 必须用 Picker：AppKit 菜单会忽略 Button 里 Image 的 opacity，导致所有 ✓ 都画出来。
            Picker(selection: selectedTheme) {
                ForEach(WebColorTheme.allCases, id: \.self) { theme in
                    Text(theme.menuTitleEnglish).tag(theme)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(L("menu.theme"), systemImage: "paintpalette.fill")
        }
    }
}

// MARK: - Tab Switching via Key Monitor (Cmd+1…9)
// Using NSEvent local monitor instead of CommandMenu so no menu item appears
// and no menu bar highlight flashes when the shortcut is pressed.

private enum TabSwitchMonitor {
    static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.option),
                  let char = event.charactersIgnoringModifiers,
                  let digit = Int(char), (1...9).contains(digit) else {
                return event
            }
            if let windows = NSApp.keyWindow?.tabbedWindows, digit <= windows.count {
                windows[digit - 1].makeKeyAndOrderFront(nil)
            }
            return nil // consumed
        }
    }
}
