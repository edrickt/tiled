import AppKit
import ImageIO
import UniformTypeIdentifiers

// Renders the neutral desktop backdrop used for the README's captures, so
// the assets never carry whatever photo happens to be on the machine's
// desktop. A smooth vertical gradient: quiet enough to keep the tiled
// windows the subject, and cheap for the GIF encoder (bands do not move).
//
//   swift tools/capture/desktop/main.swift out.png [width] [height]

let args = Array(CommandLine.arguments.dropFirst())
guard let output = args.first else {
    FileHandle.standardError.write("usage: desktop/main.swift <out.png> [width] [height]\n".data(using: .utf8)!)
    exit(2)
}
let width = args.count > 1 ? Int(args[1]) ?? 2560 : 2560
let height = args.count > 2 ? Int(args[2]) ?? 1600 : 1600

let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Deep slate at the bottom, a touch of blue light at the top.
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(srgbRed: 0.078, green: 0.086, blue: 0.118, alpha: 1),
        CGColor(srgbRed: 0.145, green: 0.163, blue: 0.220, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])

// A soft vignette keeps the corners from reading as pure flat fill.
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(srgbRed: 0.20, green: 0.23, blue: 0.32, alpha: 0.55),
        CGColor(srgbRed: 0.20, green: 0.23, blue: 0.32, alpha: 0),
    ] as CFArray,
    locations: [0, 1])!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: CGFloat(width) * 0.5, y: CGFloat(height) * 0.72), startRadius: 0,
    endCenter: CGPoint(x: CGFloat(width) * 0.5, y: CGFloat(height) * 0.72),
    endRadius: CGFloat(max(width, height)) * 0.62, options: [])

let image = context.makeImage()!
let url = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(
    atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write("cannot write \(output)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("png finalize failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(output) \(width)x\(height)")
