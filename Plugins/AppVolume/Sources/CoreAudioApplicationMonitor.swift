import AppKit
import CoreAudio
import Darwin
import Foundation
import OSLog

@MainActor
final class CoreAudioApplicationMonitor: AudioApplicationMonitoring {
    var onUpdate: ((AudioApplicationSnapshot) -> Void)?

    private let worker: any AudioApplicationObservationWorking
    private var lastSnapshot = AudioApplicationSnapshot.empty
    private var isRunning = false
    private var generation: UInt64 = 0

    init(worker: any AudioApplicationObservationWorking = CoreAudioApplicationObservationWorker()) {
        self.worker = worker
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let currentGeneration = generation
        worker.start { [weak self] snapshot in
            Task { @MainActor in
                self?.publish(snapshot, generation: currentGeneration)
            }
        }
    }

    func refresh() {
        guard isRunning else { return }
        worker.refresh()
    }

    func stop() {
        isRunning = false
        generation &+= 1
        worker.stop()
        lastSnapshot = .empty
    }

    private func publish(_ snapshot: AudioApplicationSnapshot, generation: UInt64) {
        guard isRunning, generation == self.generation, snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    deinit { worker.stop() }
}

protocol AudioApplicationObservationWorking: Sendable {
    func start(delivery: @escaping AudioApplicationObservation.Delivery)
    func refresh()
    func stop()
}

final class CoreAudioApplicationObservationWorker: AudioApplicationObservationWorking, @unchecked Sendable {
    private let queue: DispatchQueue
    private let observation: AudioApplicationObservation

    init() {
        let queue = DispatchQueue(label: "cc.ggbond.mactools.app-volume.discovery", qos: .utility)
        self.queue = queue
        observation = AudioApplicationObservation(dependencies: .init(
            processObjectIDs: CoreAudioApplicationQuery.processObjectIDs,
            snapshot: CoreAudioApplicationQuery.snapshot,
            observe: { property, callback in
                Self.observe(property, queue: queue, callback: callback)
            },
            schedule: { delay, callback in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + delay,
                               leeway: delay >= 1 ? .milliseconds(150) : .milliseconds(10))
                timer.setEventHandler(handler: callback)
                timer.resume()
                return {
                    timer.setEventHandler {}
                    timer.cancel()
                }
            }
        ))
    }

    func start(delivery: @escaping AudioApplicationObservation.Delivery) {
        queue.async { [observation] in observation.start(delivery: delivery) }
    }

    func refresh() {
        queue.async { [observation] in observation.refresh() }
    }

    func stop() {
        queue.async { [observation] in observation.stop() }
    }

    deinit { stop() }

    private static func observe(
        _ property: AudioApplicationProperty,
        queue: DispatchQueue,
        callback: @escaping @Sendable () -> Void
    ) -> AudioApplicationObservation.Cancellation? {
        var address = property.address
        let listener: AudioObjectPropertyListenerBlock = { _, _ in callback() }
        guard AudioObjectAddPropertyListenerBlock(property.objectID, &address, queue, listener) == noErr else {
            return nil
        }
        return {
            var address = property.address
            let status = AudioObjectRemovePropertyListenerBlock(property.objectID, &address, queue, listener)
            if status != noErr && status != kAudioHardwareBadObjectError {
                logger.error("Could not remove audio property listener: \(status)")
            }
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AppVolumeDiscovery"
    )
}

private enum CoreAudioApplicationQuery {
    private struct Group {
        var displayName: String
        var bundleIdentifier: String?
        var processObjectIDs: [AudioObjectID]
    }

    static func processObjectIDs() -> [AudioObjectID]? {
        objectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
    }

    static func snapshot(processObjectIDs: [AudioObjectID]) -> AudioApplicationQueryResult {
        var groups: [String: Group] = [:]
        var isComplete = true

        for processObjectID in processObjectIDs {
            guard let isRunning = boolProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) else {
                isComplete = false
                continue
            }
            guard isRunning else { continue }
            guard let pid = pidProperty(objectID: processObjectID) else {
                isComplete = false
                continue
            }
            guard pid != getpid() else { continue }

            let audioBundleIdentifier = stringProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyBundleID
            )
            let runningApplication = responsibleApplication(
                processID: pid,
                audioBundleIdentifier: audioBundleIdentifier
            )
            let bundleIdentifier = runningApplication?.bundleIdentifier ?? audioBundleIdentifier
            let stableID = bundleIdentifier ?? "pid.\(pid)"
            let displayName = runningApplication?.localizedName
                ?? bundleIdentifier?.split(separator: ".").last.map(String.init)
                ?? "PID \(pid)"

            if var group = groups[stableID] {
                group.processObjectIDs.append(processObjectID)
                groups[stableID] = group
            } else {
                groups[stableID] = Group(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    processObjectIDs: [processObjectID]
                )
            }
        }

        let applications = groups.map { id, group in
            AudioApplication(
                id: id,
                displayName: group.displayName,
                bundleIdentifier: group.bundleIdentifier,
                processObjectIDs: group.processObjectIDs.sorted()
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        let output = defaultOutputDeviceUID()
        return AudioApplicationQueryResult(
            snapshot: AudioApplicationSnapshot(applications: applications, outputDeviceUID: output.uid),
            isComplete: isComplete && output.isComplete
        )
    }

    private static func defaultOutputDeviceUID() -> (uid: String?, isComplete: Bool) {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else { return (nil, false) }
        guard deviceID != kAudioObjectUnknown else { return (nil, true) }
        let uid = stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
        return (uid, uid != nil)
    }

    private static func objectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID]? {
        var address = propertyAddress(selector: selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr else { return nil }
        guard dataSize > 0 else { return [] }
        guard Int(dataSize) % MemoryLayout<AudioObjectID>.size == 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr, Int(dataSize) % MemoryLayout<AudioObjectID>.size == 0 else { return nil }
        let returnedCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard returnedCount <= values.count else { return nil }
        return values.prefix(returnedCount).filter { $0 != kAudioObjectUnknown }
    }

    private static func pidProperty(objectID: AudioObjectID) -> pid_t? {
        var pid = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var address = propertyAddress(selector: kAudioProcessPropertyPID)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &pid
        )
        return status == noErr && pid > 0 ? pid : nil
    }

    private static func boolProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(selector: selector)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr ? value != 0 : nil
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var address = propertyAddress(selector: selector)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }

        return value as String?
    }

    private static func responsibleApplication(
        processID: pid_t,
        audioBundleIdentifier: String?
    ) -> NSRunningApplication? {
        var visited: Set<pid_t> = []
        var candidateProcessID = processID

        while candidateProcessID > 0, visited.insert(candidateProcessID).inserted {
            if let application = NSRunningApplication(processIdentifier: candidateProcessID),
               application.activationPolicy == .regular {
                return application
            }

            guard let parentProcessID = parentProcessID(processID: candidateProcessID),
                  parentProcessID != candidateProcessID else {
                break
            }
            candidateProcessID = parentProcessID
        }

        guard let audioBundleIdentifier else {
            return nil
        }

        return NSWorkspace.shared.runningApplications.first { application in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return audioBundleIdentifier == bundleIdentifier
                || audioBundleIdentifier.hasPrefix(bundleIdentifier + ".")
        }
    }

    private static func parentProcessID(processID: pid_t) -> pid_t? {
        var processInfo = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(infoSize)
        )
        guard result == Int32(infoSize), processInfo.pbi_ppid > 0 else {
            return nil
        }

        return pid_t(processInfo.pbi_ppid)
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
