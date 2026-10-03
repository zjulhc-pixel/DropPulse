import CKalam
import Foundation

// MARK: - Models

struct DeviceInfo: Decodable, Sendable {
    struct USB: Decodable { let Product: String; let SerialNumber: String }
    struct MTP: Decodable { let Model: String }
    let usbDeviceInfo: USB
    let mtpDeviceInfo: MTP

    var name: String { usbDeviceInfo.Product.isEmpty ? mtpDeviceInfo.Model : usbDeviceInfo.Product }
    var serial: String { usbDeviceInfo.SerialNumber }
}

struct Storage: Decodable, Sendable {
    struct Details: Decodable { let MaxCapability: Int64; let FreeSpaceInBytes: Int64 }
    let Sid: Int
    let Info: Details

    var total: Int64 { Info.MaxCapability }
    var free: Int64 { Info.FreeSpaceInBytes }
}

struct PhoneItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind { case folder, image, video, other }

    let path: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let date: Date

    var id: String { path }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var kind: Kind {
        if isFolder { return .folder }
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng", "bmp"].contains(ext) { return .image }
        if ["mp4", "mov", "3gp", "mkv", "webm", "m4v"].contains(ext) { return .video }
        return .other
    }
}

struct TransferProgress: Decodable, Sendable {
    struct Bytes: Decodable { let total: Int64; let sent: Int64 }
    let name: String
    let speed: Double            // MB/s
    let totalFiles: Int
    let filesSent: Int
    let bulkFileSize: Bytes
}

struct KalamError: LocalizedError {
    let type: String
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Bridge

/// Serialises every Kalam call on one thread; MTP allows a single session at a time.
final class Kalam: Sendable {
    static let shared = Kalam()
    private let queue = DispatchQueue(label: "droplet.kalam", qos: .userInitiated)

    func initialize() async throws -> DeviceInfo { try await call { _ in Initialize(onDone) } }
    func dispose() async { _ = try? await call { _ in Dispose(onDone) } as Ignored }
    func storages() async throws -> [Storage] { try await call { _ in FetchStorages(onDone) } }

    func list(_ sid: Int, _ path: String, hidden: Bool) async throws -> [PhoneItem] {
        let raw: [RawItem] = try await call(["storageId": sid, "fullPath": path, "recursive": false,
                                             "skipDisallowedFiles": false, "skipHiddenFiles": !hidden]) { Walk($0, onDone) }
        return raw.map(\.item)
    }

    func existing(_ sid: Int, _ paths: [String]) async throws -> Set<String> {
        let raw: [Exists] = try await call(["storageId": sid, "files": paths]) { FileExists($0, onDone) }
        return Set(raw.filter(\.exists).map(\.fullpath))
    }

    func makeFolder(_ sid: Int, _ path: String) async throws {
        let _: Ignored = try await call(["storageId": sid, "fullPath": path]) { MakeDirectory($0, onDone) }
    }

    func delete(_ sid: Int, _ paths: [String]) async throws {
        let _: Ignored = try await call(["storageId": sid, "files": paths]) { DeleteFile($0, onDone) }
    }

    func rename(_ sid: Int, _ path: String, to name: String) async throws {
        let _: Ignored = try await call(["storageId": sid, "fullPath": path, "newFileName": name]) { RenameFile($0, onDone) }
    }

    func download(_ sid: Int, _ paths: [String], to dir: URL,
                  progress: (@Sendable (TransferProgress) -> Void)? = nil) async throws {
        let _: Ignored = try await call(["storageId": sid, "sources": paths, "destination": dir.path,
                                         "preprocessFiles": true], progress: progress) {
            DownloadFiles($0, onIgnore, onProgress, onDone)
        }
    }

    func upload(_ sid: Int, _ files: [URL], to path: String,
                progress: (@Sendable (TransferProgress) -> Void)? = nil) async throws {
        let _: Ignored = try await call(["storageId": sid, "sources": files.map(\.path), "destination": path,
                                         "preprocessFiles": true], progress: progress) {
            UploadFiles($0, onIgnore, onProgress, onDone)
        }
    }

    private func call<T: Decodable & Sendable>(_ args: [String: Any]? = nil,
                                               progress: (@Sendable (TransferProgress) -> Void)? = nil,
                                               _ fn: @escaping @Sendable (UnsafeMutablePointer<CChar>?) -> Void) async throws -> T {
        let json = try args.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                var result = Data()
                doneSink = { result = Data(bytes: $0, count: strlen($0)) }
                progressSink = { json in
                    if let progress, let p = try? Self.unwrap(TransferProgress.self, Data(bytes: json, count: strlen(json))) {
                        progress(p)
                    }
                }
                if let json { json.withCString { fn(UnsafeMutablePointer(mutating: $0)) } } else { fn(nil) }
                cont.resume(with: Result { try Self.unwrap(T.self, result) })
            }
        }
    }

    private static func unwrap<T: Decodable>(_: T.Type, _ data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if !envelope.errorType.isEmpty { throw KalamError(type: envelope.errorType, message: envelope.error) }
        // Kalam sends `null` for "nothing": a call without a result, or an empty folder.
        guard let value = envelope.data ?? (Ignored() as? T) ?? ([Any]() as? T) else {
            throw KalamError(type: "Empty", message: "No data")
        }
        return value
    }
}

// Kalam calls back through C function pointers, which cannot capture context.
// They are only touched from the Kalam queue.
nonisolated(unsafe) private var doneSink: (UnsafeMutablePointer<CChar>) -> Void = { _ in }
nonisolated(unsafe) private var progressSink: (UnsafeMutablePointer<CChar>) -> Void = { _ in }
private let onDone: kalam_cb = { doneSink($0!) }
private let onProgress: kalam_cb = { progressSink($0!) }
private let onIgnore: kalam_cb = { _ in }

private struct Envelope<T: Decodable>: Decodable { let errorType: String; let error: String; let data: T? }
private struct Ignored: Decodable, Sendable { init() {}; init(from _: Decoder) {} }
private struct Exists: Decodable { let fullpath: String; let exists: Bool }

private struct RawItem: Decodable {
    let path: String, name: String, isFolder: Bool, size: Int64, dateAdded: String

    // Devices report local wall-clock time with a misleading "Z" suffix.
    static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    var item: PhoneItem {
        PhoneItem(path: path, name: name, isFolder: isFolder, size: size,
                  date: Self.format.date(from: dateAdded) ?? .distantPast)
    }
}
