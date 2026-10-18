import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// the picture the user pins to the left of the notch when nothing else is showing. a gif keeps its
// own timing; every frame is shrunk once to the slot's size so a big gif costs almost nothing
struct IdleArt {
    let frames: [CGImage]
    let delays: [Double]
    let total: Double

    static let types: [UTType] = [.gif, .png, .jpeg, .heic, .webP]
    private static let maxFrames = 300
    private static let pixels = 64

    // the built-in gifs shipped in the app's resources, in the order the settings picker shows them
    static let builtIns = ["pyramid-head", "cat", "ghost", "cassette", "campfire"]

    static func builtIn(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "idle")
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Niche")
    }

    static func load(_ url: URL) -> IdleArt? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary
        var frames: [CGImage] = [], delays: [Double] = []
        for index in 0..<min(CGImageSourceGetCount(source), maxFrames) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            frames.append(frame)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            // browsers treat tiny gif delays as 0.1 s, so the same gif plays at the same speed here
            delays.append(delay < 0.02 ? 0.1 : delay)
        }
        guard !frames.isEmpty else { return nil }
        // trim the empty margin around the art (same box for every frame, so it doesn't jitter) and
        // pad it back to a square, so a small figure in a big transparent canvas still fills the slot
        let box = frames.compactMap(Self.opaqueBounds).reduce(CGRect.null) { $0.union($1) }
        if !box.isNull {
            let side = Int(max(box.width, box.height))
            frames = frames.map { Self.square($0, around: box, side: side) ?? $0 }
        }
        return IdleArt(frames: frames, delays: delays, total: delays.reduce(0, +))
    }

    private static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 16 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        // context rows run bottom-up, image coordinates top-down
        return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func square(_ image: CGImage, around box: CGRect, side: Int) -> CGImage? {
        guard let cropped = image.cropping(to: box),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: (side - cropped.width) / 2, y: (side - cropped.height) / 2, width: cropped.width, height: cropped.height))
        return ctx.makeImage()
    }

    func frame(at time: Double) -> CGImage {
        guard frames.count > 1 else { return frames[0] }
        var t = time.truncatingRemainder(dividingBy: total)
        for (index, delay) in delays.enumerated() {
            if t < delay { return frames[index] }
            t -= delay
        }
        return frames[frames.count - 1]
    }
}

struct IdleArtView: View {
    let art: IdleArt
    var size: CGFloat = 20
    var cornerRadius: CGFloat = 5

    var body: some View {
        Group {
            if art.frames.count > 1 {
                TimelineView(.animation(minimumInterval: art.delays.min() ?? 0.1)) { context in
                    picture(art.frame(at: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                picture(art.frames[0])
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func picture(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 2).resizable().interpolation(.high).scaledToFit()
    }
}

struct IdleClosedView: View {
    let art: IdleArt

    var body: some View {
        HStack(spacing: 0) {
            // a bit bigger than the 20 pt song artwork, still inside the notch height with a few points to spare
            IdleArtView(art: art, size: 26, cornerRadius: 6)
                .padding(.leading, 5)
                .frame(width: MusicClosedView.slot, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
