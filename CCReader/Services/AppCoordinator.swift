import Foundation
import SwiftData

@MainActor
public class AppCoordinator: ObservableObject {
    @Published public private(set) var isInitialized = false

    private var syncService: SyncService?
    private var fileWatcher: FileWatcherService?
    private let modelContainer: ModelContainer

    // Debounce file watcher bursts into a single sync pass.
    private var debounceTask: Task<Void, Never>?
    private var metadataWarmupTask: Task<Void, Never>?
    private var pendingFiles: Set<URL> = []
    private let debounceInterval: UInt64 = 500_000_000 // 0.5 seconds

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    public func start() async {
        guard !isInitialized else { return }

        // Initialize SyncService with the container so it creates its own background contexts.
        let sync = SyncService(modelContainer: modelContainer)

        syncService = sync

        // Run the initial lightweight session index sync.
        await sync.initialSync()

        // Start real-time file watching.
        startFileWatching()
        startMetadataWarmup()

        isInitialized = true
    }

    private func startMetadataWarmup() {
        metadataWarmupTask?.cancel()
        metadataWarmupTask = Task { [weak self] in
            guard let self else { return }
            await self.syncService?.warmupSessionMetadata()
        }
    }

    private func startFileWatching() {
        let watcher = FileWatcherService { [weak self] url in
            guard let self = self else { return }
            Task { @MainActor in
                self.scheduleSync(for: url)
            }
        }
        fileWatcher = watcher
        watcher.startWatching(path: FileWatcherService.claudeProjectsPath)
    }

    /// Schedule a sync pass with debounce.
    /// Sync runs only after file changes stop for a short period.
    private func scheduleSync(for url: URL) {
        pendingFiles.insert(url)

        // Cancel the pending debounce task.
        debounceTask?.cancel()

        // Sync after the debounce interval if no new changes arrive.
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.debounceInterval ?? 2_000_000_000)
            } catch {
                return // Cancelled
            }

            guard let self = self, !Task.isCancelled else { return }

            // Sync every file collected during the debounce window.
            let files = self.pendingFiles
            self.pendingFiles.removeAll()

            for file in files {
                await self.syncService?.incrementalSync(fileURL: file)
                NotificationCenter.default.post(
                    name: .sessionDidSync,
                    object: JSONLParser.sessionId(from: file)
                )
            }
        }
    }

    /// Sync a specific session incrementally for manual refresh actions.
    public func syncSession(_ session: Session) async {
        guard let fileURL = session.jsonlFileURL else { return }
        await syncService?.incrementalSync(fileURL: fileURL)
        NotificationCenter.default.post(name: .sessionDidSync, object: session.sessionId)
    }

    public func stop() {
        debounceTask?.cancel()
        metadataWarmupTask?.cancel()
        debounceTask = nil
        metadataWarmupTask = nil
        pendingFiles.removeAll()
        fileWatcher?.stopWatching()
        fileWatcher = nil
    }
}
