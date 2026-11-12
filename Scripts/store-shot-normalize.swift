// Store screenshot normaliser: re-encode a PNG without an alpha channel, or centre a smaller image on a black canvas.
// Usage: swift Scripts/store-shot-normalize.swift <in.png> <out.png> <width> <height>
// CoreGraphics and ImageIO only. Never scales: an image larger than the target is an error.
import Darwin
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("store-shot-normalize: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    fail("usage: store-shot-normalize.swift <in.png> <out.png> <width> <height>")
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard let width = Int(arguments[3]), let height = Int(arguments[4]), width > 0, height > 0 else {
    fail("width and height must be positive integers")
}

guard let data = try? Data(contentsOf: input) else { fail("cannot read \(input.path)") }
guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot decode \(input.path) as an image")
}
let sourceWidth = image.width
let sourceHeight = image.height
guard sourceWidth <= width, sourceHeight <= height else {
    fail("\(sourceWidth)x\(sourceHeight) is larger than \(width)x\(height); refusing to scale")
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB colour space") }
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fail("cannot make an RGB bitmap context")
}
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.draw(image, in: CGRect(x: (width - sourceWidth) / 2, y: (height - sourceHeight) / 2,
                               width: sourceWidth, height: sourceHeight))
guard let normalized = context.makeImage() else { fail("cannot render the normalised image") }
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot write \(output.path)")
}
CGImageDestinationAddImage(destination, normalized, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot finish \(output.path)") }
print("ok \(arguments[1]) -> \(arguments[2]) \(width)x\(height) alpha=none")
