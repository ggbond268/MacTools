import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerPresentationTests: XCTestCase {
    func testTreemapPartitionsWithoutOverlapAndPreservesArea() {
        let rows = (1...20).map { number -> StorageExplorerRow in
            let item = StorageItem(name: "\(number)", path: "/\(number)", url: URL(fileURLWithPath: "/\(number)"), isDirectory: false, size: Int64(number))
            return StorageExplorerRow(item: item, name: item.name, bytes: item.size, sizeLabel: "", percentage: "", kind: "", modified: .distantPast, dateLabel: "")
        }
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 300)
        let tiles = StorageExplorerTreemapLayout.tiles(rows: rows, in: bounds)
        XCTAssertEqual(tiles.count, rows.count)
        for (i, tile) in tiles.enumerated() {
            XCTAssertEqual(tile.rect.width * tile.rect.height / (bounds.width * bounds.height), Double(tile.row.bytes) / 210, accuracy: 0.000001)
            for other in tiles.dropFirst(i + 1) {
                let intersection = tile.rect.intersection(other.rect)
                XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.00001)
            }
        }
        XCTAssertTrue(StorageExplorerTreemapLayout.tiles(rows: rows, in: .zero).isEmpty)
    }

    func testLargestFilesSearchesAllDescendantsAndUsesAllocatedMetric() {
        let root = "/fixture"
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        for i in 0..<3 {
            let path = root + "/nested/file-\(i).bin"
            snapshot.apply([StorageItem(name: "file-\(i).bin", path: path, url: URL(fileURLWithPath: path), isDirectory: false,
                                       size: Int64(i + 1), allocatedSize: Int64(100 - i), parentPath: root + "/nested")])
        }
        let result = StorageExplorerPresentation.make(snapshot: snapshot, directory: root, mode: .largestFiles,
            metric: .allocated, query: "nested", sort: .size, ascending: false)
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows.first?.bytes, 100)
        XCTAssertEqual(result.total, 297)
        let types = StorageExplorerPresentation.make(snapshot: snapshot, directory: root, mode: .fileTypes,
            metric: .logical, query: "", sort: .size, ascending: false)
        XCTAssertEqual(types.rows.count, 1)
        XCTAssertEqual(types.rows.first?.bytes, 6)
        XCTAssertEqual(types.rows.first?.item.childCount, 3)
    }

    func testChartGroupsOverflowWithoutLosingBytes() {
        var snapshot = StorageExplorerSnapshot(rootPath: "/fixture")
        for i in 0..<250 {
            let path = "/fixture/\(i)"
            snapshot.apply([StorageItem(name: "\(i)", path: path, url: URL(fileURLWithPath: path),
                isDirectory: false, size: 10, parentPath: "/fixture")])
        }
        let result = StorageExplorerPresentation.make(snapshot: snapshot, directory: "/fixture", mode: .folders,
            metric: .logical, query: "", sort: .size, ascending: false)
        XCTAssertEqual(result.chart.count, 161)
        XCTAssertEqual(result.chart.reduce(0) { $0 + $1.bytes }, 2_500)
        XCTAssertEqual(result.chart.last?.id, "group:other")
        XCTAssertEqual(result.rows.count, 250)
    }

    func testTreemapViewportKeepsZoomAnchorStable() {
        let size = CGSize(width: 800, height: 500)
        let anchor = CGPoint(x: 300, y: 180)
        var viewport = StorageExplorerTreemapViewport()

        let contentBefore = viewport.contentPoint(for: anchor)
        viewport.zoom(to: 3, around: anchor, in: size)
        let contentAfter = viewport.contentPoint(for: anchor)

        XCTAssertEqual(contentAfter.x, contentBefore.x, accuracy: 0.001)
        XCTAssertEqual(contentAfter.y, contentBefore.y, accuracy: 0.001)
        XCTAssertEqual(viewport.scale, 3)
    }

    func testTreemapViewportClampsPanAndReset() {
        let size = CGSize(width: 800, height: 500)
        var viewport = StorageExplorerTreemapViewport()
        viewport.zoom(to: 2, around: CGPoint(x: 400, y: 250), in: size)
        viewport.pan(by: CGSize(width: 2_000, height: -2_000), in: size)

        XCTAssertEqual(viewport.offset.width, 0)
        XCTAssertEqual(viewport.offset.height, -500)

        viewport.reset()
        XCTAssertEqual(viewport, StorageExplorerTreemapViewport())
    }
}
