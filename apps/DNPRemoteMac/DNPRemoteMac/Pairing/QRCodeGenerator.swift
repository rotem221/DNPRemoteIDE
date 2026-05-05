import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates a high-contrast QR code image for a string payload, suitable for on-screen display.
enum QRCodeGenerator {

    /// Returns an `NSImage` rendered at the requested pixel size, with quiet zone, dark code on light bg.
    static func image(for payload: String, size: CGFloat = 240, foreground: NSColor = .black, background: NSColor = .white) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard var ciImage = filter.outputImage else { return nil }

        // Recolor: false-color filter to apply our fg/bg.
        let recolor = CIFilter.falseColor()
        recolor.inputImage = ciImage
        recolor.color0 = CIColor(color: foreground) ?? .black   // dark squares
        recolor.color1 = CIColor(color: background) ?? .white   // light bg
        if let recolored = recolor.outputImage { ciImage = recolored }

        let scale = size / max(ciImage.extent.width, 1)
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        return nsImage
    }
}
