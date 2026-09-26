import XCTest
@testable import SystemStatusPlugin

final class SystemStatusProcessAccountingTests: XCTestCase {
    func testParsingPreservesMulticoreCPUAndExecutablePathsWithSpaces() throws {
        let samples = SystemStatusProcessAccounting.parse("""
          10 1 501 245.7 /Applications/Example Browser.app/Contents/MacOS/Example Browser
          11 10 501 12,5 /usr/bin/worker
          12 1 501 nan /usr/bin/invalid
          13 1 501 -1 /usr/bin/invalid
          malformed
        """)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].cpuPercent, 245.7)
        XCTAssertEqual(samples[0].command, "/Applications/Example Browser.app/Contents/MacOS/Example Browser")
        XCTAssertEqual(samples[1].cpuPercent, 12.5)
        XCTAssertNil(samples[0].memoryBytes)
    }

    func testApplicationsIncludeHelpersChildrenAndResponsibleServicesBeforeRanking() throws {
        let samples = [
            sample(10, command: "/Applications/Browser.app/Contents/MacOS/Browser", cpu: 40, memory: 100),
            sample(11, parent: 10, command: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", cpu: 40, memory: 200),
            sample(12, parent: 10, command: "/usr/bin/worker", cpu: 40, memory: 300),
            sample(13, responsible: 10, command: "/System/Library/WebKit.xpc/Contents/MacOS/WebKit", cpu: 40, memory: 400),
            sample(20, parent: 10, command: "/Applications/Editor.app/Contents/MacOS/Editor", cpu: 100, memory: 500),
            sample(30, command: "/usr/bin/memory-heavy", cpu: 1, memory: 2_000)
        ]
        let groups = SystemStatusProcessAccounting.aggregate(samples)
        XCTAssertEqual(groups.count, 3)
        let browser = try XCTUnwrap(groups.first { $0.displayName == "Browser" })
        XCTAssertEqual(browser.pid, 10)
        XCTAssertEqual(browser.processCount, 4)
        XCTAssertEqual(browser.cpuPercent, 160)
        XCTAssertEqual(browser.memoryBytes, 1_000)
        let leaders = SystemStatusProcessAccounting.candidates(groups, limit: 1)
        XCTAssertEqual(Set(leaders.map(\.pid)), [10, 30])

        let helpersOnly = SystemStatusProcessAccounting.aggregate([samples[1]])
        XCTAssertEqual(helpersOnly.first?.id, browser.id)
    }

    func testIncompleteFootprintIsUnavailableAndIdentitiesAreNotMergedByName() throws {
        let groups = SystemStatusProcessAccounting.aggregate([
            sample(10, command: "/Applications/Editor.app/Contents/MacOS/Editor", memory: 100),
            sample(11, parent: 10, command: "/usr/bin/worker", memory: nil),
            sample(20, command: "/Other/Editor.app/Contents/MacOS/Editor", memory: 0),
            sample(30, uid: 502, command: "/Applications/Editor.app/Contents/MacOS/Editor", memory: 50),
            sample(40, uid: 0, responsible: 10, command: "/usr/bin/service", memory: nil)
        ])
        XCTAssertEqual(groups.count, 4)
        let editor = try XCTUnwrap(groups.first { $0.pid == 10 })
        XCTAssertEqual(editor.processCount, 2)
        XCTAssertNil(editor.memoryBytes)
        let ordered = groups.sorted { SystemStatusProcessAccounting.ordered($0, before: $1, by: .memory) }
        XCTAssertEqual(Array(ordered.prefix(2)).map(\.pid), [30, 20])
        XCTAssertEqual(groups.first { $0.pid == 40 }?.processCount, 1)
    }

    func testCandidatesRetainBothRankingsForEverySupportedLimit() {
        let groups = SystemStatusProcessAccounting.aggregate((1 ... 25).map { pid in
            sample(pid, command: "/usr/bin/process-\(pid)", cpu: Double(26 - pid), memory: UInt64(pid * 1024))
        })
        for limit in SystemStatusProcessLimit.allCases {
            let candidates = SystemStatusProcessAccounting.candidates(groups, limit: limit.rawValue)
            let expected = Set(1 ... limit.rawValue).union(Set((26 - limit.rawValue) ... 25))
            XCTAssertEqual(Set(candidates.map(\.pid)), expected)
            XCTAssertLessThanOrEqual(candidates.count, limit.rawValue * 2)
        }
    }

    private func sample(
        _ pid: Int, parent: Int = 1, uid: UInt32 = 501, responsible: Int? = nil,
        command: String, cpu: Double = 0, memory: UInt64?
    ) -> SystemStatusProcessSample {
        SystemStatusProcessSample(
            pid: pid, parentPID: parent, userID: uid, cpuPercent: cpu,
            command: command, memoryBytes: memory, responsiblePID: responsible
        )
    }
}
