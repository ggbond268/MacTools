import Darwin
import Foundation
import XCTest

/// Shared xattr helpers for quarantine tests. They call the xattr syscalls directly so
/// assertions stay independent from `PluginQuarantineInspector`'s own implementation.
enum PluginQuarantineTestSupport {
    static let attributeName = "com.apple.quarantine"

    static func setQuarantine(
        atPath path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let valueBytes = Array("0083;00000000;TestBrowser;".utf8)
        let result = valueBytes.withUnsafeBytes { buffer in
            setxattr(path, attributeName, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        XCTAssertEqual(
            result,
            0,
            "setxattr failed for \(path): \(String(cString: strerror(errno)))",
            file: file,
            line: line
        )
    }

    static func hasQuarantine(atPath path: String) -> Bool {
        getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    static func quarantinedPaths(under rootURL: URL) -> [String] {
        var paths: [String] = []

        if hasQuarantine(atPath: rootURL.path) {
            paths.append(rootURL.path)
        }

        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        while let itemURL = enumerator?.nextObject() as? URL {
            if hasQuarantine(atPath: itemURL.path) {
                paths.append(itemURL.path)
            }
        }

        return paths
    }
}
