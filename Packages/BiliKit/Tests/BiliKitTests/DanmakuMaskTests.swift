@testable import BiliKit
import CoreGraphics
import XCTest

final class DanmakuMaskTests: XCTestCase {
    func testWebMaskStructure() throws {
        let mask = try WebMask(data: Fixture.data("danmaku_mask.webmask"))
        XCTAssertEqual(mask.segments.map(\.time), [0, 10000])
        XCTAssertEqual(mask.segmentIndex(at: 0), 0)
        XCTAssertEqual(mask.segmentIndex(at: 9999), 0)
        XCTAssertEqual(mask.segmentIndex(at: 10000), 1)
        XCTAssertEqual(mask.segmentIndex(at: 999_999), 1)
        let frames = try mask.frames(ofSegment: 0)
        XCTAssertEqual(frames.map(\.time), [0, 33, 66])
        XCTAssertTrue(frames[0].svg.hasPrefix("data:image/svg+xml;base64,"))
        XCTAssertEqual(try mask.frames(ofSegment: 1).map(\.time), [10000, 10033])
    }

    func testFrameShapeCoversBackgroundNotThePerson() throws {
        let mask = try WebMask(data: Fixture.data("danmaku_mask.webmask"))
        let frame = try mask.frames(ofSegment: 0)[0]
        let shape = try XCTUnwrap(SVGMask.shape(fromFrame: frame.svg))
        XCTAssertEqual(shape.size, CGSize(width: 180, height: 320))
        let box = shape.path.boundingBox
        XCTAssertGreaterThan(box.width, 50)
        XCTAssertTrue(CGRect(x: -1, y: -1, width: 182, height: 322).contains(box), "\(box) lies inside the frame (y flipped by the group transform)")
    }

    func testRejectsOtherData() {
        XCTAssertThrowsError(try WebMask(data: Data("not a mask at all".utf8)))
        XCTAssertThrowsError(try WebMask(data: Data("MASK".utf8) + Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5])))
    }

    func testPathCommands() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><g transform="translate(0,50) scale(1,-1)">
        <path d="M10 10 l20 0 0 20 -20 0z m50-5 h10 v10 H60 Z"/><path d="M0 0 C 1 1,2 2,3 3 s4 4 5 5 Q1 1 2 2 t3 3"/></g></svg>
        """
        let shape = try XCTUnwrap(SVGMask.shape(fromSVG: svg))
        XCTAssertEqual(shape.size, CGSize(width: 100, height: 50))
        // The square from (10,10) to (30,30) flips to y 20…40.
        XCTAssertTrue(shape.path.contains(CGPoint(x: 20, y: 30)))
        XCTAssertFalse(shape.path.contains(CGPoint(x: 20, y: 15)))
        // Second subpath: relative move from the closed square's start.
        XCTAssertTrue(shape.path.contains(CGPoint(x: 65, y: 50 - 10)))
        // Curves (C, reflected s, Q, reflected t) end where their last points say: (0,0) → (3,3) → (8,8) → (2,2) → (5,5).
        let curves = try XCTUnwrap(SVGMask.shape(fromSVG: "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 C 1 1,2 2,3 3 s4 4 5 5 Q1 1 2 2 t3 3\"/></svg>"))
        XCTAssertEqual(curves.path.currentPoint, CGPoint(x: 5, y: 5))
    }

    func testAlphaImageMarksTheShape() throws {
        let shape = try XCTUnwrap(SVGMask.shape(fromSVG: "<svg viewBox=\"0 0 100 50\"><path d=\"M0 0 H50 V50 H0 Z\"/></svg>"))
        let image = try XCTUnwrap(shape.alphaImage(maxSide: 20))
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 10)
        let bytes = [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
        let row = image.bytesPerRow
        XCTAssertGreaterThan(bytes[2 * row + 2], 200, "left half (inside the shape) is opaque")
        XCTAssertLessThan(bytes[2 * row + 17], 50, "right half is clear")
        XCTAssertGreaterThan(bytes[8 * row + 2], 200)
        // Vertical orientation: a shape over the top half only must fill the first rows of the bitmap
        // (CGImage row 0 is the top, as CALayer contents draw it).
        let top = try XCTUnwrap(SVGMask.shape(fromSVG: "<svg viewBox=\"0 0 100 50\"><path d=\"M0 0 H100 V25 H0 Z\"/></svg>"))
        let topImage = try XCTUnwrap(top.alphaImage(maxSide: 20))
        let topBytes = [UInt8](try XCTUnwrap(topImage.dataProvider?.data) as Data)
        XCTAssertGreaterThan(topBytes[1 * topImage.bytesPerRow + 10], 200, "row 1 (top) is inside")
        XCTAssertLessThan(topBytes[8 * topImage.bytesPerRow + 10], 50, "row 8 (bottom) is outside")
    }

    func testNumberScanner() {
        XCTAssertEqual(SVGMask.numbers("10-5.5e2,3.2.5 -.5"), [10, -550, 3.2, 0.5, -0.5])
    }

    func testMaskInfoFromPlayerInfo() {
        let info = JSON(["dm_mask": ["fps": 30, "mask_url": "//upos-sz-staticcos-cmask.bilivideo.com/cmaskboss/1_30_0.webmask?x=1"]])
        XCTAssertEqual(API.danmakuMask(fromPlayerInfo: info)?.url.absoluteString, "https://upos-sz-staticcos-cmask.bilivideo.com/cmaskboss/1_30_0.webmask?x=1")
        XCTAssertNil(API.danmakuMask(fromPlayerInfo: JSON(["dm_mask": NSNull()])))
    }
}
