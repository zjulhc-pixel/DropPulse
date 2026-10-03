import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails without copying whole files: photos use the small JPEG the camera embeds in
/// the Exif block near the start of the file, videos let AVFoundation read just the index and
/// first frame. Results are kept in memory and on disk.
@MainActor final class Thumbs {
    static let shared = Thumbs()

    private let memory = NSCache<NSString, NSImage>()
    private let dir = Store.shared.cacheDir.appending(path: "thumbs")

    func image(for item: PhoneItem) async -> NSImage? {
        let key = "\(item.path)|\(item.size)|\(item.date.timeIntervalSince1970)".stableHash
        if let image = memory.object(forKey: key as NSString) { return image }
        let file = dir.appending(path: key + ".jpg")
        var data = await Task.detached { try? Data(contentsOf: file) }.value
        if data == nil, let mtp = Store.shared.device, !Task.isCancelled {
            data = await Self.make(item, mtp)
            if let data {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: file)
            }
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    nonisolated private static func make(_ item: PhoneItem, _ mtp: MTP) async -> Data? {
        var image: CGImage?
        let head = item.kind == .image ? try? await mtp.read(item, length: 128 << 10) : nil
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: PhoneAsset(item, mtp))
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.appliesPreferredTrackTransform = true
            image = try? await generator.image(at: .zero).image
        } else if let head, let thumb = exifThumbnail(head) {
            image = thumb
        } else if let head, let range = heifThumbnail(head),
                  let jpeg = try? await mtp.read(item, offset: Int64(range.lowerBound), length: range.count) {
            // HEIF's own preview item (Hasselblad, some cameras): fetch just that, and turn it the
            // way the photo is turned — ImageIO reads that from the header alone.
            var sparse = Data(count: Int(item.size))
            sparse.replaceSubrange(0..<head.count, with: head)
            let properties = CGImageSourceCreateWithData(sparse as CFData, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
            image = upright(jpeg, orientation: properties?[kCGImagePropertyOrientation] as? Int ?? 1)
        } else if ["jpg", "jpeg"].contains(item.ext), let data = try? await mtp.thumbnail(item),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else if item.size < 40 << 20, let whole = try? await mtp.read(item, length: Int(item.size)),
                  let source = CGImageSourceCreateWithData(whole as CFData, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ] as CFDictionary)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The JPEG in Exif IFD1 (JPEG APP1 or a HEIC Exif item), turned upright.
    nonisolated static func exifThumbnail(_ data: Data) -> CGImage? {
        // The Exif header is followed by a TIFF header ("II*" or "MM*"). In HEIC, "Exif" also
        // appears earlier as an item type name, so look for the real one.
        var search = data.startIndex..<data.endIndex
        var found: Int?
        while found == nil, let marker = data.range(of: Data("Exif\0\0".utf8), in: search) {
            let header = data.dropFirst(marker.upperBound - data.startIndex).prefix(3)
            if Array(header) == [0x49, 0x49, 0x2A] || Array(header) == [0x4D, 0x4D, 0x00] { found = marker.upperBound }
            search = marker.upperBound..<data.endIndex
        }
        guard let tiff = found else { return nil }
        let little = data[tiff] == 0x49
        func number(_ offset: Int, _ size: Int) -> Int {
            let start = tiff + offset
            guard offset >= 0, start + size <= data.count else { return 0 }
            let bytes = data[start..<start + size]
            return (little ? bytes.reversed() : Array(bytes)).reduce(0) { $0 << 8 | Int($1) }
        }
        func entries(_ ifd: Int) -> [(tag: Int, value: Int)] {
            (0..<number(ifd, 2)).map { i in
                let entry = ifd + 2 + 12 * i
                let type = number(entry + 2, 2)
                return (number(entry, 2), type == 3 ? number(entry + 8, 2) : number(entry + 8, 4))
            }
        }
        let ifd0 = number(4, 4)
        let orientation = entries(ifd0).first { $0.tag == 0x112 }?.value ?? 1
        let ifd1 = number(ifd0 + 2 + 12 * number(ifd0, 2), 4)
        let tags = Dictionary(entries(ifd1).map { ($0.tag, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard ifd1 > 0, let offset = tags[0x201], let length = tags[0x202], length > 0,
              tiff + offset + length <= data.count
        else { return nil }
        return upright(data[tiff + offset..<tiff + offset + length], orientation: orientation)
    }

    /// A small upright image from JPEG data.
    nonisolated static func upright(_ jpeg: Data, orientation: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
              ] as CFDictionary)
        else { return nil }
        guard orientation > 1 else { return small }
        let turned = CIImage(cgImage: small).oriented(CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up)
        return context.createCGImage(turned, from: turned.extent)
    }

    /// Where a HEIF file keeps its thumbnail item (the item with a "thmb" reference), from the
    /// meta box at the start of the file.
    nonisolated static func heifThumbnail(_ data: Data) -> Range<Int>? {
        let d = Data(data)
        func number(_ offset: Int, _ size: Int) -> Int {
            guard offset >= 0, offset + size <= d.count else { return 0 }
            return d[offset..<offset + size].reduce(0) { $0 << 8 | Int($1) }
        }
        func boxes(_ start: Int, _ end: Int) -> [(type: String, body: Int, end: Int)] {
            var found: [(String, Int, Int)] = [], offset = start
            while offset + 8 <= end {
                var size = number(offset, 4), header = 8
                if size == 1 { size = number(offset + 8, 8); header = 16 } else if size == 0 { size = end - offset }
                guard size >= header else { break }
                found.append((String(decoding: d[offset + 4..<offset + 8], as: UTF8.self), offset + header, min(offset + size, end)))
                offset += size
            }
            return found
        }
        guard let meta = boxes(0, d.count).first(where: { $0.type == "meta" }) else { return nil }
        let children = boxes(meta.body + 4, meta.end)
        guard let iref = children.first(where: { $0.type == "iref" }),
              let iloc = children.first(where: { $0.type == "iloc" }) else { return nil }
        let idSize = d[iref.body] == 0 ? 2 : 4
        guard let thumb = boxes(iref.body + 4, iref.end).first(where: { $0.type == "thmb" }).map({ number($0.body, idSize) })
        else { return nil }

        let version = Int(d[iloc.body])
        var p = iloc.body + 4
        let offsetSize = Int(d[p] >> 4), lengthSize = Int(d[p] & 15)
        let baseSize = Int(d[p + 1] >> 4), indexSize = version > 0 ? Int(d[p + 1] & 15) : 0
        let wide = version < 2 ? 2 : 4
        p += 2
        let count = number(p, wide); p += wide
        for _ in 0..<count {
            let id = number(p, wide); p += wide
            var method = 0
            if version > 0 { method = number(p, 2) & 15; p += 2 }
            p += 2                                                  // data reference index
            let base = number(p, baseSize); p += baseSize
            let extents = number(p, 2); p += 2
            var range: Range<Int>?
            for _ in 0..<extents {
                p += indexSize
                let offset = base + number(p, offsetSize); p += offsetSize
                let length = number(p, lengthSize); p += lengthSize
                range = range.map { min($0.lowerBound, offset)..<max($0.upperBound, offset + length) } ?? offset..<offset + length
            }
            if id == thumb { return method == 0 ? range : nil }
        }
        return nil
    }

    nonisolated private static let context = CIContext()
}

/// A video on the phone that AVFoundation reads on demand, for thumbnails and streaming playback.
final class PhoneAsset: AVURLAsset, @unchecked Sendable {
    private let loader: Loader

    init(_ item: PhoneItem, _ mtp: MTP) {
        loader = Loader(item: item, mtp: mtp)
        super.init(url: URL(string: "droplet://\(item.handle)/video.\(item.ext)")!, options: nil)
        resourceLoader.setDelegate(loader, queue: .global(qos: .userInitiated))
    }

    private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let item: PhoneItem
        let mtp: MTP

        init(item: PhoneItem, mtp: MTP) { self.item = item; self.mtp = mtp }

        func resourceLoader(_ loader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            Task {
                if let info = request.contentInformationRequest {
                    info.contentType = (UTType(filenameExtension: item.ext) ?? .movie).identifier
                    info.contentLength = item.size
                    info.isByteRangeAccessSupported = true
                }
                if let wanted = request.dataRequest {
                    var offset = wanted.currentOffset
                    let end = wanted.requestsAllDataToEndOfResource ? item.size : wanted.requestedOffset + Int64(wanted.requestedLength)
                    do {
                        while offset < end, !request.isCancelled {
                            let chunk = try await mtp.read(item, offset: offset, length: Int(min(end - offset, 1 << 20)))
                            guard !chunk.isEmpty else { break }
                            wanted.respond(with: chunk)
                            offset += Int64(chunk.count)
                        }
                    } catch {
                        request.finishLoading(with: error)
                        return
                    }
                }
                request.finishLoading()
            }
            return true
        }
    }
}

extension String {
    var stableHash: String {
        SHA256.hash(data: Data(utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
