import AppKit
import Foundation

/// Stores clip images on disk instead of inside the SwiftData store.
///
/// Full-resolution `tiffRepresentation` of a 5K screenshot is ~50 MB uncompressed;
/// keeping those in the database made it grow by gigabytes in a week. We keep a
/// small PNG thumbnail in the model and the full image as a PNG file on disk.
enum ImageStore {
    static let thumbnailMaxSize: CGFloat = 320

    /// Immutable so it is safe to touch from any isolation domain.
    ///
    /// Demo runs get their own folder. They use an in-memory database holding
    /// only the invented clips, and `pruneOrphanedImages` at startup then treats
    /// every real image file as belonging to no clip and deletes it — which is
    /// exactly what happened: the rows survived with their text and thumbnails
    /// while the full-size images were destroyed.
    private static let directory: URL = {
        var folder = "CopyWell/Images"
        #if DEBUG
        if CommandLine.arguments.contains("--demo-content") { folder = "CopyWell/DemoImages" }
        #endif
        // The parentheses matter. Without them the folder was appended to the
        // temporary-directory fallback only, so images went straight into
        // Application Support — and pruning, which empties this folder of
        // everything that is not a live image, deleted the history database
        // sitting next to them on every launch.
        let base = (applicationSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// Clip images are named after their content hash: 32 hex digits, `.png`.
    private static func isClipImageName(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        let stem = name.dropLast(4)
        return stem.count == 32 && stem.allSatisfy(\.isHexDigit)
    }

    /// Moves images that build 36 wrote into Application Support itself back
    /// into the images folder, where their clips look for them.
    static func recoverMisplacedImages() {
        guard let support = applicationSupport,
              support.standardizedFileURL != directory.standardizedFileURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: support.path) else { return }
        for name in names where isClipImageName(name) {
            let misplaced = support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url(for: name).path) {
                try? FileManager.default.removeItem(at: misplaced)
            } else {
                try? FileManager.default.moveItem(at: misplaced, to: url(for: name))
            }
        }
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Saves PNG bytes that have already been encoded.
    ///
    /// The capture path hashes the normalised PNG and then stores the very same
    /// bytes, so encoding twice would be both wasteful and a chance for the two
    /// to disagree.
    @discardableResult
    static func write(data: Data, fileName: String) -> Bool {
        do {
            try data.write(to: url(for: fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Writes the image as PNG and returns the file name to store in the model.
    @discardableResult
    static func write(_ image: NSImage, fileName: String) -> String? {
        guard let data = png(from: image, maxSize: nil) else { return nil }
        let target = url(for: fileName)
        do {
            try data.write(to: target, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func read(fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    static func remove(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Removes image files that no longer belong to any live clip.
    ///
    /// Only files named the way clip images are named: if the folder is ever
    /// wrong again, whatever else lives there is left alone.
    static func pruneOrphans(keeping liveFileNames: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isClipImageName(name) && !liveFileNames.contains(name) {
            remove(fileName: name)
        }
    }

    /// True pixel dimensions. `NSImage.size` is in points, so a Retina
    /// screenshot reports half its real size there.
    static func pixelSize(of image: NSImage) -> CGSize {
        for case let rep as NSBitmapImageRep in image.representations {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        if let rep = image.representations.first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    static func thumbnail(from image: NSImage) -> Data? {
        png(from: image, maxSize: thumbnailMaxSize)
    }

    /// Renders `image` to PNG, optionally downscaled so its longest side is
    /// `maxSize` pixels.
    ///
    /// Sized from the pixels, not from `image.size`: that is in points, so a
    /// Retina screenshot was stored at half its resolution — it pasted back
    /// blurry and half the size, and OCR ran on the smaller copy. The point
    /// size is written into the PNG as its resolution, so the picture still
    /// pastes at the size it was on screen.
    static func png(from image: NSImage, maxSize: CGFloat?) -> Data? {
        let points = image.size
        var pixels = pixelSize(of: image)
        if pixels.width <= 0 || pixels.height <= 0 { pixels = points }
        guard pixels.width > 0, pixels.height > 0, points.width > 0, points.height > 0 else { return nil }

        var target = pixels
        var targetPoints = points
        if let maxSize, max(pixels.width, pixels.height) > maxSize {
            let scale = maxSize / max(pixels.width, pixels.height)
            target = CGSize(width: (pixels.width * scale).rounded(),
                            height: (pixels.height * scale).rounded())
            targetPoints = target
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(target.width), 1),
            pixelsHigh: max(Int(target.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        // Drawing is done in pixels; the point size is applied afterwards so
        // the encoder records the right resolution.
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = targetPoints

        return rep.representation(using: .png, properties: [:])
    }
}
