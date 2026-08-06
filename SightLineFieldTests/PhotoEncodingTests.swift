import XCTest
@testable import SightLineField

#if canImport(UIKit)
import UIKit

@MainActor
final class PhotoEncodingTests: XCTestCase {
    func testReEncodesDecodableImageToJpeg() {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let pngData = image.pngData() else {
            XCTFail("Failed to render source PNG")
            return
        }

        let result = JobDetailView.jpegData(from: pngData)

        XCTAssertFalse(result.isEmpty)
        XCTAssertNotNil(UIImage(data: result))
        XCTAssertNotEqual(result, pngData)
    }

    func testFallsBackToRawBytesWhenUndecodable() {
        let garbage = Data([0x01, 0x02, 0x03, 0x04])

        let result = JobDetailView.jpegData(from: garbage)

        XCTAssertEqual(result, garbage)
    }
}
#endif
