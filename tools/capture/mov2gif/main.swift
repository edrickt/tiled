import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// mov2gif <in.mov> <out.gif> [--fps N] [--width W] [--start S] [--end E]
//         [--crop x,y,w,h] [--speed N] [--colors N] [--frames dir]

struct Options {
    var input = ""
    var output = ""
    var fps: Double = 12
    var width: Int = 1280
    var start: Double = 0
    var end: Double = -1
    var crop: CGRect? = nil
    var speed: Double = 1.0
    var colors: Int = 128
    var framesDir: String? = nil
}

var opts = Options()
let args = Array(CommandLine.arguments.dropFirst())
var i = 0
var positional: [String] = []
while i < args.count {
    let a = args[i]
    func value() -> String {
        i += 1
        return i < args.count ? args[i] : ""
    }
    switch a {
    case "--fps": opts.fps = Double(value()) ?? opts.fps
    case "--width": opts.width = Int(value()) ?? opts.width
    case "--start": opts.start = Double(value()) ?? 0
    case "--end": opts.end = Double(value()) ?? -1
    case "--speed": opts.speed = Double(value()) ?? 1
    case "--colors": opts.colors = Int(value()) ?? 128
    case "--frames": opts.framesDir = value()
    case "--crop":
        let p = value().split(separator: ",").compactMap { Double($0) }
        if p.count == 4 { opts.crop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
    default: positional.append(a)
    }
    i += 1
}
guard positional.count >= 2 else {
    FileHandle.standardError.write("usage: mov2gif <in.mov> <out.gif> [--fps N] [--width W] [--start S] [--end E] [--speed N] [--colors N] [--crop x,y,w,h]\n".data(using: .utf8)!)
    exit(2)
}
opts.input = positional[0]
opts.output = positional[1]

let asset = AVURLAsset(url: URL(fileURLWithPath: opts.input))
let duration = try await asset.load(.duration).seconds
let end = opts.end < 0 ? duration : min(opts.end, duration)
let span = max(0.001, end - opts.start)

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

let times: [CMTime] = stride(from: 0.0, to: span, by: 1.0 / opts.fps).map {
    CMTime(seconds: opts.start + $0, preferredTimescale: 600)
}

var frames: [CGImage] = []
for t in times {
    if let img = try? await gen.image(at: t).image { frames.append(img) }
}
guard !frames.isEmpty else {
    FileHandle.standardError.write("no frames extracted\n".data(using: .utf8)!)
    exit(1)
}
print("extracted \(frames.count) frames of \(duration)s (\(frames[0].width)x\(frames[0].height))")

// Scale + optional crop into a fixed canvas.
let srcW = CGFloat(frames[0].width)
let srcH = CGFloat(frames[0].height)
let cropRect = opts.crop ?? CGRect(x: 0, y: 0, width: srcW, height: srcH)
let outW = opts.width
let outH = Int(((CGFloat(outW) * cropRect.height) / cropRect.width).rounded())
let scale = CGFloat(outW) / cropRect.width

func render(_ img: CGImage) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(
        img,
        in: CGRect(
            x: -cropRect.minX * scale, y: -cropRect.minY * scale,
            width: srcW * scale, height: srcH * scale))
    return ctx.makeImage()!
}

let rendered = frames.map(render)

if let dir = opts.framesDir {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (n, f) in rendered.enumerated() {
        let url = URL(fileURLWithPath: String(format: "%@/frame-%04d.png", dir, n))
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, f, nil)
            CGImageDestinationFinalize(dest)
        }
    }
    print("wrote \(rendered.count) frames to \(dir)")
}

// GIF: pre-quantize frames to a shared-ish palette. ImageIO writes GIF with
// its own per-frame quantization, which is dithery at low color counts; a
// quick median cut per frame is not available, so hand ImageIO RGB frames and
// let it quantize, but scale first to keep the byte count sane.
let delay = (1.0 / opts.fps) / opts.speed
let outURL = URL(fileURLWithPath: opts.output)
guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.gif.identifier as CFString, rendered.count, nil)
else {
    FileHandle.standardError.write("cannot create \(opts.output)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)
let frameProps = [
    kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: delay,
        kCGImagePropertyGIFUnclampedDelayTime: delay,
    ]
] as CFDictionary
for f in rendered { CGImageDestinationAddImage(dest, f, frameProps) }
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("gif finalize failed\n".data(using: .utf8)!)
    exit(1)
}
let size = (try? FileManager.default.attributesOfItem(atPath: opts.output)[.size] as? Int) ?? 0
print("wrote \(opts.output) \(outW)x\(outH) \(size / 1024)KB")
