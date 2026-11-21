import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WorkbenchCore

/// Renders lines of black text on white into a PNG, like a screen region would look.
private func renderText(_ lines: [String], to url: URL, fontSize: CGFloat = 28) throws {
    let width = 900, lineHeight = Int(fontSize * 1.6), height = lineHeight * lines.count + 40
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    for (i, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 20, y: CGFloat(height - 20 - lineHeight * (i + 1) + lineHeight / 4))
        CTLineDraw(ctLine, ctx)
    }
    try writePNG(try #require(ctx.makeImage()), to: url)
}

private func renderQR(_ payload: String, to url: URL) throws {
    let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    let output = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    // Add a white margin so the detector has a quiet zone.
    let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -40, dy: -40)))
    let cg = try #require(CIContext().createCGImage(padded, from: padded.extent))
    try writePNG(cg, to: url)
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func tempPNG() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("wb-ocr-\(UUID().uuidString).png")
}

@Suite("Text grab")
struct TextGrabTests {
    @Test func recognisesRenderedText() async throws {
        let url = tempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        try renderText(["Error 403: Access denied", "Retry in 30 seconds"], to: url)

        let result = try await TextRecognizer.recognize(imageAt: url)
        #expect(result.lines.count == 2)
        #expect(result.lines.first?.contains("403") == true)
        #expect(result.lines.first?.localizedCaseInsensitiveContains("access denied") == true)
        #expect(result.lines.last?.localizedCaseInsensitiveContains("retry in 30 seconds") == true)
        #expect(result.summary == "Copied 8 words")
    }

    @Test func recognisesSpanishAccents() async throws {
        let url = tempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        try renderText(["¿Dónde está la estación?"], to: url, fontSize: 36)
        let result = try await TextRecognizer.recognize(imageAt: url)
        let text = result.clipboardText
        #expect(text.contains("Dónde"))
        #expect(text.contains("estación"))
    }

    @Test func readsQRCodes() async throws {
        let url = tempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        try renderQR("https://example.com/workbench", to: url)
        let result = try await TextRecognizer.recognize(imageAt: url)
        #expect(result.codes == ["https://example.com/workbench"])
        #expect(result.clipboardText == "https://example.com/workbench")
        #expect(result.summary == "Copied QR code link")
    }

    @Test func blankImageIsEmpty() async throws {
        let url = tempPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        try renderText([""], to: url)
        let result = try await TextRecognizer.recognize(imageAt: url)
        #expect(result.isEmpty)
    }

    @Test func readingOrderMergesSameLine() {
        // Vision coordinates: origin bottom-left, so a higher midY means higher on screen.
        let boxes: [(CGRect, String)] = [
            (CGRect(x: 0.5, y: 0.80, width: 0.3, height: 0.1), "world"),
            (CGRect(x: 0.0, y: 0.10, width: 0.4, height: 0.1), "second line"),
            (CGRect(x: 0.0, y: 0.81, width: 0.3, height: 0.1), "Hello"),
        ]
        #expect(TextRecognizer.orderedLines(boxes) == ["Hello world", "second line"])
    }

    @Test func historyDedupesAndCaps() throws {
        var history = GrabHistory(limit: 3)
        history.add("one")
        history.add("two")
        history.add("  one \n")      // same text again → moves to top, no duplicate
        #expect(history.records.map(\.text) == ["one", "two"])
        history.add("three")
        history.add("four")
        #expect(history.records.map(\.text) == ["four", "three", "one"])
        history.add("   ")           // ignored
        #expect(history.records.count == 3)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-hist-\(UUID().uuidString)/grabs.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try history.save(to: url)
        #expect(GrabHistory.load(from: url) == history)
        #expect(GrabHistory.load(from: url.appendingPathExtension("missing")).records.isEmpty)
    }
}
