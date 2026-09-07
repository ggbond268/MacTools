import CoreServices
import Foundation

/// A stream exists only for the selected root. Dropped events invalidate the entire in-memory cache.
// The stream is immutable after initialization. An in-flight flush retains the observer,
// so teardown cannot race it; callbacks are always delivered on the main queue.
final class StorageExplorerFileObserver: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let changed: @Sendable ([String]?) -> Void

    init?(path: String, changed: @escaping @Sendable ([String]?) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let observer = Unmanaged<StorageExplorerFileObserver>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let resetFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            if (0..<count).contains(where: { flags[$0] & resetFlags != 0 }) { observer.changed(nil) }
            else { observer.changed(paths) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                if let stream { FSEventStreamFlushSync(stream) }
                continuation.resume()
            }
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
