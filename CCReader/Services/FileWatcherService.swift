import Foundation
import Combine

class FileWatcherService: ObservableObject {
    @Published private(set) var isWatching = false
    @Published private(set) var lastChange: FileChange?

    struct FileChange {
        let url: URL
        let timestamp: Date
    }

    private var stream: FSEventStreamRef?
    private let callback: (URL) -> Void
    private let eventQueue = DispatchQueue(label: "com.kuaner.ccreader.filewatcher", qos: .userInitiated)
    private var watchPath: String?

    init(callback: @escaping (URL) -> Void) {
        self.callback = callback
    }

    deinit {
        stopWatching()
    }

    func startWatching(path: String) {
        guard !isWatching else { return }

        watchPath = path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray

        stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()

                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]

                for i in 0..<numEvents {
                    let path = paths[i]
                    let flags = eventFlags[i]

                    // Handle file changes only and ignore directory events.
                    if flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                        // Watch only session JSONL files.
                        if path.hasSuffix(".jsonl") {
                            let url = URL(fileURLWithPath: path)
                            DispatchQueue.main.async {
                                watcher.lastChange = FileChange(url: url, timestamp: Date())
                                watcher.callback(url)
                            }
                        }
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // Short coalescing window to keep updates feeling real-time.
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream = stream else { return }

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)

        DispatchQueue.main.async {
            self.isWatching = true
        }

        print("Started watching: \(path)")
    }

    func stopWatching() {
        guard let stream = stream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        self.stream = nil
        DispatchQueue.main.async {
            self.isWatching = false
        }

        print("Stopped watching")
    }

    // MARK: - Helpers

    static var claudeProjectsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects"
    }

    // Enumerate existing JSONL files on startup.
    static func existingJSONLFiles() -> [URL] {
        let projectsPath = claudeProjectsPath
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: projectsPath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jsonl" {
                files.append(url)
            }
        }

        return files
    }
}
