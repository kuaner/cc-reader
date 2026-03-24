import Foundation
import SwiftData
import Combine

@MainActor
class AppCoordinator: ObservableObject {
    @Published private(set) var isInitialized = false
    @Published private(set) var isSyncing = false
    @Published private(set) var messageCount = 0
    @Published private(set) var syncProgress: String = ""

    private var syncService: SyncService?
    private var fileWatcher: FileWatcherService?
    private let modelContext: ModelContext
    private var cancellables = Set<AnyCancellable>()

    // デバウンス用
    private var debounceTask: Task<Void, Never>?
    private var pendingFiles: Set<URL> = []
    private let debounceInterval: UInt64 = 500_000_000 // 0.5秒

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func start() async {
        guard !isInitialized else { return }

        // SyncServiceを初期化
        let sync = SyncService(modelContext: modelContext)
        syncService = sync

        // SyncServiceの状態を監視
        sync.$isSyncing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSyncing)

        sync.$syncedMessageCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$messageCount)

        sync.$syncProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$syncProgress)

        // 初回フルシンク
        await sync.fullSync()

        // リアルタイムファイル監視を開始
        startFileWatching()

        isInitialized = true
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

    /// デバウンス付きで同期をスケジュール
    /// ファイル変更後、一定時間変更がなくなってから同期を実行
    private func scheduleSync(for url: URL) {
        pendingFiles.insert(url)

        // 既存のタイマーをキャンセル
        debounceTask?.cancel()

        // 2秒後に同期（その間に変更がなければ）
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.debounceInterval ?? 2_000_000_000)
            } catch {
                return // キャンセルされた
            }

            guard let self = self, !Task.isCancelled else { return }

            // 溜まったファイルをまとめて同期
            let files = self.pendingFiles
            self.pendingFiles.removeAll()

            for file in files {
                await self.syncService?.incrementalSync(fileURL: file)
            }
        }
    }

    /// 特定セッションの差分を同期（手動トリガー用）
    func syncSession(_ session: Session) async {
        guard let fileURL = session.jsonlFileURL else { return }
        await syncService?.incrementalSync(fileURL: fileURL)
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingFiles.removeAll()
        fileWatcher?.stopWatching()
        fileWatcher = nil
    }
}
