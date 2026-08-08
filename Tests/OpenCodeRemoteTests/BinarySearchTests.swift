import XCTest
@testable import OpenCodeRemote

// MARK: - BinarySearchTests
//
// Copertura di `BinarySearch.find(_:_:)` su array ordinati.

final class BinarySearchTests: XCTestCase {

    func testFind_whenValueInArray_shouldReturnCorrectIndex() {
        let array = [1, 3, 5, 7, 9]
        XCTAssertEqual(BinarySearch.find(array, 1), 0)
        XCTAssertEqual(BinarySearch.find(array, 5), 2)
        XCTAssertEqual(BinarySearch.find(array, 9), 4)
    }

    func testFind_whenValueAbsent_shouldReturnNil() {
        let array = [1, 3, 5, 7, 9]
        XCTAssertNil(BinarySearch.find(array, 0))
        XCTAssertNil(BinarySearch.find(array, 2))
        XCTAssertNil(BinarySearch.find(array, 6))
        XCTAssertNil(BinarySearch.find(array, 10))
    }

    func testFind_whenEmptyArray_shouldReturnNil() {
        XCTAssertNil(BinarySearch.find([Int](), 1))
    }

    func testFind_whenSingleElementMatches_shouldReturnZero() {
        XCTAssertEqual(BinarySearch.find([42], 42), 0)
    }

    func testFind_whenSingleElementDoesNotMatch_shouldReturnNil() {
        XCTAssertNil(BinarySearch.find([42], 41))
    }

    func testFind_whenDuplicates_shouldReturnAnIndexContainingTheValue() {
        let array = [1, 2, 2, 2, 3]
        let found = BinarySearch.find(array, 2)
        XCTAssertNotNil(found)
        XCTAssertEqual(array[found!], 2)
    }

    func testFind_whenValueAtBoundaries_shouldReturnFirstAndLastIndex() {
        let array = [10, 20, 30, 40, 50]
        XCTAssertEqual(BinarySearch.find(array, 10), 0)
        XCTAssertEqual(BinarySearch.find(array, 50), array.count - 1)
    }

    func testFind_whenStringsAndNegativeNumbers_shouldWork() {
        XCTAssertEqual(BinarySearch.find(["a", "b", "c"], "b"), 1)
        XCTAssertEqual(BinarySearch.find(["a", "b", "c"], "a"), 0)
        XCTAssertEqual(BinarySearch.find(["a", "b", "c"], "d"), nil)
        XCTAssertEqual(BinarySearch.find([-5, -3, -1, 0, 2], -3), 1)
        XCTAssertNil(BinarySearch.find([-5, -3, -1, 0, 2], -4))
    }

    func testFind_whenLargeArray_shouldFindElementsInLogNSteps() {
        let array = Array(0..<10_000)
        XCTAssertEqual(BinarySearch.find(array, 0), 0)
        XCTAssertEqual(BinarySearch.find(array, 4_999), 4_999)
        XCTAssertEqual(BinarySearch.find(array, 9_999), 9_999)
        XCTAssertNil(BinarySearch.find(array, 10_000))
    }
}
