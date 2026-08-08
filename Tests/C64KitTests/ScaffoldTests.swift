import XCTest
@testable import C64Kit

final class ScaffoldTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(C64KitInfo.name, "C64Kit")
    }
}
