import AppKit
import Darwin
import Foundation

private final class StalledPlainTextProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        while true { sleep(60) }
    }
}

private final class LargeDataProvider: NSObject, NSPasteboardItemDataProvider {
    let byteCount: Int

    init(byteCount: Int) {
        self.byteCount = byteCount
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setData(Data(repeating: 0x41, count: byteCount), forType: type)
    }
}

private func argumentValue(after option: String) -> String? {
    guard let optionIndex = CommandLine.arguments.firstIndex(of: option),
          CommandLine.arguments.indices.contains(optionIndex + 1) else {
        return nil
    }
    return CommandLine.arguments[optionIndex + 1]
}

private func currentVirtualMemorySize() -> UInt64? {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? info.virtual_size : nil
}

private func currentPhysicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

private func installAddressSpaceGrowthLimit(additionalByteCount: UInt64) -> Bool {
    guard let currentVirtualMemorySize = currentVirtualMemorySize(),
          additionalByteCount <= UInt64.max - currentVirtualMemorySize else {
        return false
    }
    let maximumAddressSpace = currentVirtualMemorySize + additionalByteCount
    var limit = rlimit(
        rlim_cur: rlim_t(maximumAddressSpace),
        rlim_max: rlim_t(maximumAddressSpace)
    )
    return setrlimit(RLIMIT_AS, &limit) == 0
}

private func maximumResidentMemoryFootprint(additionalByteCount: UInt64) -> UInt64? {
    guard let baseline = currentPhysicalFootprint(),
          additionalByteCount <= UInt64.max - baseline else {
        return nil
    }
    return baseline + additionalByteCount
}

private func recordWatchdogState(_ state: String, at path: String?) {
    guard let path else { return }
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(state)\n".utf8))
    } catch {
        return
    }
}

private final class ResidentMemoryWatchdog: @unchecked Sendable {
    private let maximumPhysicalFootprint: UInt64
    private let stateFilePath: String?
    private let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(
            label: "clipboard-pasteboard-memory-watchdog",
            qos: .userInitiated
        )
    )
    private var isRunning = false

    init(maximumPhysicalFootprint: UInt64, stateFilePath: String?) {
        self.maximumPhysicalFootprint = maximumPhysicalFootprint
        self.stateFilePath = stateFilePath
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let maximumPhysicalFootprint = maximumPhysicalFootprint
        timer.setEventHandler {
            if let physicalFootprint = currentPhysicalFootprint(),
               physicalFootprint > maximumPhysicalFootprint {
                _exit(4)
            }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        recordWatchdogState("active", at: stateFilePath)
        timer.resume()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer.setEventHandler {}
        timer.cancel()
        recordWatchdogState("idle", at: stateFilePath)
    }
}

if let optionIndex = CommandLine.arguments.firstIndex(of: "--stall-plain-text-owner"),
   CommandLine.arguments.indices.contains(optionIndex + 1) {
    let pasteboardName = NSPasteboard.Name(CommandLine.arguments[optionIndex + 1])
    let pasteboard = NSPasteboard(name: pasteboardName)
    let provider = StalledPlainTextProvider()
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.string])
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { exit(2) }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    RunLoop.current.run()
    withExtendedLifetime(provider) {}
    exit(0)
}

if let pasteboardNameValue = argumentValue(after: "--large-data-owner"),
   let byteCountValue = argumentValue(after: "--large-data-byte-count"),
   let byteCount = Int(byteCountValue), byteCount > 0 {
    let pasteboard = NSPasteboard(name: .init(pasteboardNameValue))
    let provider = LargeDataProvider(byteCount: byteCount)
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.png])
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { exit(2) }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    RunLoop.current.run()
    withExtendedLifetime(provider) {}
    exit(0)
}

let defaultMemoryHeadroom = UInt64(384 * 1_024 * 1_024)
let memoryHeadroom = argumentValue(after: "--memory-headroom-byte-count")
    .flatMap(UInt64.init) ?? defaultMemoryHeadroom
guard memoryHeadroom >= 8 * 1_024 * 1_024,
      memoryHeadroom <= 1_024 * 1_024 * 1_024,
      installAddressSpaceGrowthLimit(additionalByteCount: memoryHeadroom),
      let maximumPhysicalFootprint = maximumResidentMemoryFootprint(
          additionalByteCount: memoryHeadroom
      ) else {
    exit(3)
}
let watchdogStateFilePath = argumentValue(after: "--watchdog-state-file")

let responseDelayMicroseconds: useconds_t = {
    guard let milliseconds = argumentValue(after: "--response-delay-milliseconds").flatMap(UInt32.init),
          milliseconds <= 5_000 else { return 0 }
    return milliseconds * 1_000
}()
let allocationTestPasteboardName = argumentValue(after: "--allocate-when-pasteboard-name")
let allocationTestByteCount = argumentValue(after: "--allocate-byte-count").flatMap(Int.init)

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let maximumRequests: Int? = {
    guard let optionIndex = CommandLine.arguments.firstIndex(of: "--maximum-requests"),
          CommandLine.arguments.indices.contains(optionIndex + 1),
          let value = Int(CommandLine.arguments[optionIndex + 1]),
          value > 0 else {
        return nil
    }
    return value
}()
let lingerAfterMaximumRequestsMicroseconds: useconds_t = {
    guard let milliseconds = argumentValue(after: "--linger-after-maximum-requests-milliseconds")
        .flatMap(UInt32.init),
        milliseconds <= 5_000 else { return 0 }
    return milliseconds * 1_000
}()
var completedRequestCount = 0

while maximumRequests.map({ completedRequestCount < $0 }) ?? true {
    do {
        let requestData = try ClipboardPasteboardReaderWire.readFrame(
            from: input,
            maximumByteCount: ClipboardPasteboardReaderWire.maximumRequestFrameByteCount
        )
        let request = try ClipboardPasteboardReaderWire.decode(
            ClipboardPasteboardReaderRequest.self,
            from: requestData
        )
        let watchdog = ResidentMemoryWatchdog(
            maximumPhysicalFootprint: maximumPhysicalFootprint,
            stateFilePath: watchdogStateFilePath
        )
        watchdog.start()
        defer { watchdog.stop() }
        if request.pasteboardName == allocationTestPasteboardName,
           let allocationTestByteCount,
           allocationTestByteCount > 0,
           allocationTestByteCount <= 512 * 1_024 * 1_024 {
            let allocation = Data(repeating: 0x41, count: allocationTestByteCount)
            allocation.withUnsafeBytes { bytes in
                _ = bytes.last
                usleep(100_000)
            }
            withExtendedLifetime(allocation) {}
        }
        let response = ClipboardPasteboardReaderWire.read(request)
        if responseDelayMicroseconds > 0 { usleep(responseDelayMicroseconds) }
        try ClipboardPasteboardReaderWire.writeFrame(
            ClipboardPasteboardReaderWire.encode(response),
            to: output
        )
        completedRequestCount += 1
    } catch ClipboardPasteboardReaderWireError.unexpectedEndOfFile {
        break
    } catch {
        break
    }
}

if maximumRequests != nil, lingerAfterMaximumRequestsMicroseconds > 0 {
    // Keep the process alive after closing stdin so the parent deterministically exercises the
    // stale-session write boundary instead of depending on Process.isRunning propagation timing.
    try? input.close()
    usleep(lingerAfterMaximumRequestsMicroseconds)
}
