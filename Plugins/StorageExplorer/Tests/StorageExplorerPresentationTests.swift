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

    func testReviewBasketReducesTopLevelAndNestedSmallerAggregates() throws {
        let root = "/fixture"
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        snapshot.apply([
            StorageItem(name: "fixture", path: root, url: URL(fileURLWithPath: root), isDirectory: true, size: 100),
            StorageItem(name: "folder", path: root + "/folder", url: URL(fileURLWithPath: root + "/folder"),
                        isDirectory: true, size: 80, parentPath: root),
            StorageItem(name: "visible", path: root + "/folder/visible", url: URL(fileURLWithPath: root + "/folder/visible"),
                        isDirectory: false, size: 30, parentPath: root + "/folder")
        ])
        let initial = StorageExplorerHierarchyLayout.make(
            snapshot: snapshot,
            directory: root,
            metric: .logical,
            excluding: [],
            otherName: "Other"
        )
        let folder = try XCTUnwrap(initial.first { $0.id == root + "/folder" })
        XCTAssertEqual(folder.bytes, 80)
        XCTAssertEqual(folder.children.first { $0.isAggregate }?.bytes, 50)

        let reduced = StorageExplorerHierarchyLayout.make(
            snapshot: snapshot,
            directory: root,
            metric: .logical,
            excluding: [root + "/folder/visible"],
            otherName: "Other"
        )
        let reducedFolder = try XCTUnwrap(reduced.first { $0.id == root + "/folder" })
        XCTAssertEqual(reducedFolder.bytes, 50)
        XCTAssertEqual(reducedFolder.children.first { $0.isAggregate }?.bytes, 50)
        XCTAssertEqual(reduced.first { $0.isAggregate }?.bytes, 20)
    }

    func testHierarchyColorKeysFollowStableSizeRankAndDescendantsInheritGroup() throws {
        let root = "/fixture"
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        snapshot.apply([
            StorageItem(name: "fixture", path: root, url: URL(fileURLWithPath: root),
                        isDirectory: true, size: 175, allocatedSize: 175),
            StorageItem(name: "largest", path: root + "/largest", url: URL(fileURLWithPath: root + "/largest"),
                        isDirectory: true, size: 100, allocatedSize: 100, parentPath: root),
            StorageItem(name: "child", path: root + "/largest/child", url: URL(fileURLWithPath: root + "/largest/child"),
                        isDirectory: false, size: 100, allocatedSize: 100, parentPath: root + "/largest"),
            StorageItem(name: "middle", path: root + "/middle", url: URL(fileURLWithPath: root + "/middle"),
                        isDirectory: false, size: 50, allocatedSize: 50, parentPath: root),
            StorageItem(name: "smallest", path: root + "/smallest", url: URL(fileURLWithPath: root + "/smallest"),
                        isDirectory: false, size: 25, allocatedSize: 25, parentPath: root)
        ])

        let nodes = StorageExplorerHierarchyLayout.make(
            snapshot: snapshot,
            directory: root,
            metric: .allocated,
            excluding: [],
            otherName: "Other"
        )

        XCTAssertTrue(try XCTUnwrap(nodes.first { $0.item.name == "largest" }).colorKey.hasPrefix("size-rank:0:"))
        XCTAssertTrue(try XCTUnwrap(nodes.first { $0.item.name == "middle" }).colorKey.hasPrefix("size-rank:1:"))
        XCTAssertTrue(try XCTUnwrap(nodes.first { $0.item.name == "smallest" }).colorKey.hasPrefix("size-rank:2:"))
        let largest = try XCTUnwrap(nodes.first { $0.item.name == "largest" })
        XCTAssertEqual(largest.children.first?.colorKey, largest.colorKey)
    }

}
