import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Photo thumbnails. Kalam can't read MTP thumbnails, so visible photos are downloaded in
/// small batches, downsampled, and kept on disk. Tiles that scroll away cancel their request,
/// and the newest requests go first, so the grid fills where the user is looking.
@MainActor final class Thumbs {
    static let shared = Thumbs()

    private let memory = NSCache<NSString, NSImage>()
    private var waiting: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var queue: [PhoneItem] = []
    private var busy = false
    private let dir = Store.shared.cacheDir.appending(path: "thumbs")

    func image(for item: PhoneItem) async -> NSImage? {
        let key = Self.key(item)
        if let image = memory.object(forKey: key as NSString) { return image }
        let file = dir.appending(path: key + ".jpg")
        if let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value, let image = NSImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[key, default: []].append(continuation)
                queue.append(item)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(item) }
        }
    }

    private func cancel(_ item: PhoneItem) {
        queue.removeAll { $0 == item }
        waiting.removeValue(forKey: Self.key(item))?.forEach { $0.resume(returning: nil) }
    }

    private func pump() {
        guard !busy, !queue.isEmpty, let sid = Store.shared.storage?.Sid else { return }
        busy = true
        let batch = Array(queue.suffix(6))
        queue.removeLast(batch.count)
        let dir = dir
        Task {
            let made = await Task.detached { await Self.render(batch, sid: sid, into: dir) }.value
            for item in batch {
                let key = Self.key(item)
                let image = made.contains(key) ? NSImage(contentsOf: dir.appending(path: key + ".jpg")) : nil
                if let image { memory.setObject(image, forKey: key as NSString) }
                waiting.removeValue(forKey: key)?.forEach { $0.resume(returning: image) }
            }
            busy = false
            pump()
        }
    }

    nonisolated private static func render(_ items: [PhoneItem], sid: Int, into dir: URL) async -> Set<String> {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? await Kalam.shared.download(sid, items.map(\.path), to: temp)) != nil else { return [] }

        var made = Set<String>()
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary
        for item in items {
            let key = key(item)
            guard let source = CGImageSourceCreateWithURL(temp.appending(path: item.name) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  let out = CGImageDestinationCreateWithURL(dir.appending(path: key + ".jpg") as CFURL,
                                                            UTType.jpeg.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(out) { made.insert(key) }
        }
        return made
    }

    nonisolated static func key(_ item: PhoneItem) -> String {
        "\(item.path)|\(item.size)|\(item.date.timeIntervalSince1970)".stableHash
    }
}

extension String {
    var stableHash: String {
        SHA256.hash(data: Data(utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
