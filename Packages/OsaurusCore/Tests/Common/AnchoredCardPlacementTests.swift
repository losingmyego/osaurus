import Foundation
import Testing

@testable import OsaurusCore

@Suite("Anchored card placement")
struct AnchoredCardPlacementTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let cardSize = CGSize(width: 532, height: 440)

    @Test func opensAboveTheAnchorWithAnEightPointGap() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 200, y: 100, width: 160, height: 28),
            size: cardSize,
            visibleFrame: display
        )
        #expect(result == CGRect(x: 200, y: 136, width: 532, height: 440))
    }

    @Test func opensBelowWhenTheTopEdgeHasInsufficientSpace() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 200, y: 850, width: 160, height: 28),
            size: cardSize,
            visibleFrame: display
        )
        #expect(result == CGRect(x: 200, y: 402, width: 532, height: 440))
    }

    @Test func thirdColumnExpansionStaysInsideTheRightDisplayEdge() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 1300, y: 100, width: 100, height: 28),
            size: CGSize(width: 792, height: 440),
            visibleFrame: display
        )
        #expect(result.maxX == 1428)
        #expect(result.width == 792)
    }

    @Test func narrowDisplayConstrainsBothWidthAndHeight() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 180, y: 40, width: 80, height: 30),
            size: cardSize,
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 500)
        )
        #expect(result.width == 296)
        #expect(result.minX == 12)
        #expect(result.minY == 78)
        #expect(result.maxY == 488)
    }

    @Test func rightToLeftAlignsTheLeadingEdgeWithTheAnchor() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 900, y: 100, width: 160, height: 28),
            size: cardSize,
            visibleFrame: display,
            rightToLeft: true
        )
        #expect(result.maxX == 1060)
    }

    @Test func externalDisplayMayHaveANegativeCoordinateOrigin() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: -200, y: 100, width: 160, height: 28),
            size: cardSize,
            visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )
        #expect(result.maxX == -12)
        #expect(result.minY == 136)
    }

    @Test func constrainedHeightUsesTheLargerAvailableSide() {
        let result = AnchoredCardPlacement.frame(
            anchor: CGRect(x: 200, y: 450, width: 100, height: 28),
            size: cardSize,
            visibleFrame: display
        )
        #expect(result.height == 430)
        #expect(result.minY == 12)
    }
}
