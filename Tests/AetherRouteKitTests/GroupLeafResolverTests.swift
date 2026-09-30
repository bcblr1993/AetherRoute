import AetherRouteKit
import XCTest

final class GroupLeafResolverTests: XCTestCase {
    func testResolvesLeafBehindNestedGroup() {
        let chains = ["Proxy → Auto → Tokyo", "Proxy → Auto → Tokyo", "Proxy → Auto → Seoul"]
        XCTAssertEqual(GroupLeafResolver.leaf(throughGroup: "Auto", chains: chains), "Tokyo")
    }

    func testAcceptsAsciiArrows() {
        XCTAssertEqual(GroupLeafResolver.leaf(throughGroup: "Auto", chains: ["Proxy -> Auto -> Tokyo"]), "Tokyo")
    }

    func testIgnoresChainsThatDoNotPassThroughGroup() {
        let chains = ["DIRECT", "Proxy → Singapore", "Streaming → Auto2 → Tokyo"]
        XCTAssertNil(GroupLeafResolver.leaf(throughGroup: "Auto", chains: chains))
    }

    func testGroupAsLastHopIsNotALeaf() {
        XCTAssertNil(GroupLeafResolver.leaf(throughGroup: "Auto", chains: ["Proxy → Auto"]))
    }

    func testTieKeepsFirstSeenNode() {
        let chains = ["Auto → Seoul", "Auto → Tokyo"]
        XCTAssertEqual(GroupLeafResolver.leaf(throughGroup: "Auto", chains: chains), "Seoul")
    }

    func testEmptyInput() {
        XCTAssertNil(GroupLeafResolver.leaf(throughGroup: "Auto", chains: []))
    }
}
