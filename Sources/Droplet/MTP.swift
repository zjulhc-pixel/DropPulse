import Foundation
import IOKit
import IOUSBHost

struct Storage: Sendable { let total: Int64; let free: Int64 }

struct PhoneItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind { case folder, image, video, other }

    let path: String
    let handle: UInt32
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

struct MTPError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A small MTP initiator on top of IOUSBHost — just what Droplet needs from an Android phone.
/// The actor runs on its own serial queue, so blocking USB I/O never stalls Swift's thread pool.
/// Large reads are split into chunks with a yield between them, so browsing and thumbnails
/// keep flowing while a transfer runs.
actor MTP {
    nonisolated let name: String
    nonisolated let serial: String

    private let queue = DispatchSerialQueue(label: "droplet.mtp")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let interface: IOUSBHostInterface
    private let input: IOUSBHostPipe, output: IOUSBHostPipe
    private let packetSize: Int
    private let buffer = NSMutableData(length: 4 << 20)!
    private var transaction: UInt32 = 0
    private var timeout: TimeInterval = 3          // short until the session is open: a stuck phone re-enumerates
    private var storageID: UInt32 = 0
    private var handles: [String: UInt32] = ["/": 0]

    // MARK: Connecting

    /// The MTP interface of the first attached phone, if any.
    nonisolated static func findInterface() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let type = property(service, "bInterfaceClass") as? Int
            if type == 6 || (type == 0xFF && property(service, "kUSBString") as? String == "MTP") { return service }
            IOObjectRelease(service)
        }
        return nil
    }

    nonisolated static func serial(of service: io_service_t) -> String {
        property(device(of: service), "USB Serial Number") as? String ?? ""
    }

    /// The process holding the interface exclusively, from IORegistry's "pid 123, name".
    nonisolated static func owner(of service: io_service_t) -> (pid: pid_t, name: String)? {
        guard let owner = property(service, "UsbExclusiveOwner") as? String,
              let comma = owner.firstIndex(of: ","), let pid = pid_t(owner.dropFirst(4).prefix(upTo: comma))
        else { return nil }
        return (pid, owner[comma...].dropFirst().trimmingCharacters(in: .whitespaces))
    }

    static func connect(_ service: io_service_t, onDetach: @escaping @Sendable () -> Void) async throws -> MTP {
        let mtp = try MTP(service, onDetach: onDetach)
        try await mtp.openSession()
        return mtp
    }

    private init(_ service: io_service_t, onDetach: @escaping @Sendable () -> Void) throws {
        let device = Self.device(of: service)
        name = Self.property(device, "USB Product Name") as? String ?? "Android"
        serial = Self.property(device, "USB Serial Number") as? String ?? ""
        interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil) { _, message, _ in
            if message == 0xE000_0010 { onDetach() }      // kIOMessageServiceIsTerminated
        }
        var bulkIn: IOUSBHostPipe?, bulkOut: IOUSBHostPipe?
        for address in (1...15).flatMap({ [$0, $0 | 0x80] }) {
            guard let pipe = try? interface.copyPipe(withAddress: address),
                  pipe.descriptors.pointee.descriptor.bmAttributes & 3 == 2 else { continue }   // bulk
            if address & 0x80 != 0 { bulkIn = bulkIn ?? pipe } else { bulkOut = bulkOut ?? pipe }
        }
        guard let bulkIn, let bulkOut else { throw MTPError("This phone doesn’t offer file transfer.") }
        input = bulkIn
        output = bulkOut
        packetSize = Int(bulkOut.descriptors.pointee.descriptor.wMaxPacketSize)
    }

    private func openSession() throws {
        // Still Image class "Device Reset": recovers a phone left mid-transaction by another app.
        let reset = IOUSBDeviceRequest(bmRequestType: 0x21, bRequest: 0x66, wValue: 0, wIndex: 0, wLength: 0)
        var count = 0
        _ = try? interface.__send(reset, data: nil, bytesTransferred: &count, completionTimeout: 2)
        try? input.clearStall()
        try? output.clearStall()
        try transact(0x1002, [1])                       // OpenSession
        timeout = 10
    }

    func close() {
        _ = try? transact(0x1003)                      // CloseSession
        interface.destroy()
    }

    /// On quit: end the session so the phone isn't left mid-conversation.
    nonisolated func closeNow() {
        queue.sync { assumeIsolated { $0.close() } }
    }

    // MARK: Files

    /// Nil while the phone is locked: Android hides its storage until it is unlocked.
    func storage() throws -> Storage? {
        var ids = Reader(try fetch(0x1004))                                             // GetStorageIDs
        guard let id = ids.u32Array().first else { return nil }
        storageID = id
        var info = Reader(try fetch(0x1005, [id]))                                      // GetStorageInfo
        info.offset = 6
        return Storage(total: Int64(info.u64()), free: Int64(info.u64()))
    }

    func list(_ path: String, hidden: Bool) throws -> [PhoneItem] {
        let parent = try handle(path)
        // GetObjectPropList, all properties, one level deep: the whole folder in one request.
        var reader = Reader(try fetch(0x9805, [parent, 0, 0xFFFF_FFFF, 0, 1]))
        var rows: [UInt32: Row] = [:]
        for _ in 0..<reader.u32() {
            let handle = reader.u32(), property = reader.u16(), type = reader.u16()
            switch property {
            case 0xDC01: rows[handle, default: Row()].storage = reader.u32()
            case 0xDC02: rows[handle, default: Row()].isFolder = reader.u16() == 0x3001
            case 0xDC04: rows[handle, default: Row()].size = Int64(reader.u64())
            case 0xDC07: rows[handle, default: Row()].name = reader.string()
            case 0xDC09: rows[handle, default: Row()].date = Self.date(reader.string())
            case 0xDC0B: rows[handle, default: Row()].parent = reader.u32()
            default: reader.skip(type)
            }
        }
        return rows.compactMap { handle, row in
            guard row.parent == parent, row.storage == storageID, !row.name.isEmpty else { return nil }
            let itemPath = (path as NSString).appendingPathComponent(row.name)
            handles[itemPath] = handle
            guard hidden || !row.name.hasPrefix(".") else { return nil }
            return PhoneItem(path: itemPath, handle: handle, name: row.name, isFolder: row.isFolder,
                             size: row.isFolder ? 0 : row.size, date: row.date)
        }
    }

    /// Every file and folder inside `folder`, with paths relative to its parent.
    func walk(_ folder: PhoneItem) throws -> [(item: PhoneItem, relative: String)] {
        try list(folder.path, hidden: true).flatMap { child in
            let relative = folder.name + "/" + child.name
            let inner = child.isFolder ? try walk(child).map { ($0.item, folder.name + "/" + $0.relative) } : []
            return [(child, relative)] + inner
        }
    }

    func read(_ item: PhoneItem, offset: Int64 = 0, length: Int) throws -> Data {
        try Task.checkCancellation()
        let length = Int(min(Int64(length), item.size - offset))
        guard length > 0 else { return Data() }
        return try fetch(0x95C1, [item.handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(length)])
    }

    /// The phone's own thumbnail; Android offers one for JPEG files.
    func thumbnail(_ item: PhoneItem) throws -> Data {
        try Task.checkCancellation()
        return try fetch(0x100A, [item.handle])                                          // GetThumb
    }

    func download(_ item: PhoneItem, to file: URL, progress: @Sendable (Int64) -> Void = { _ in }) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        var offset: Int64 = 0
        while offset < item.size {
            try Task.checkCancellation()
            let length = min(item.size - offset, 8 << 20)
            try transact(0x95C1, [item.handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(length)]) {
                try out.write(contentsOf: $0)                                            // GetPartialObject64
            }
            offset += length
            progress(length)
            await Task.yield()                          // let thumbnails and browsing through
        }
    }

    func upload(_ url: URL, to folder: String, progress: @Sendable (Int64) -> Void = { _ in }) throws {
        try Task.checkCancellation()
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let size = isFolder ? 0 : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let path = (folder as NSString).appendingPathComponent(url.lastPathComponent)
        let reply = try transact(0x100C, [storageID, rootAware(try handle(folder))],                // SendObjectInfo
                                 data: objectInfo(name: url.lastPathComponent, size: size, isFolder: isFolder))
        handles[path] = reply[2]
        if isFolder {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try upload(child, to: path, progress: progress)
            }
            return
        }
        // SendObject, streamed. Every write but the last is a whole number of packets, so the
        // phone only sees the end of the data phase at the end of the file.
        try command(0x100D)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let total = 12 + Int(size)
        var chunk = header(length: total, type: 2, code: 0x100D) + (try file.read(upToCount: (8 << 20) - 12) ?? Data())
        while !chunk.isEmpty {
            try write(chunk)
            progress(Int64(chunk.count))
            chunk = try file.read(upToCount: 8 << 20) ?? Data()
        }
        if total % packetSize == 0 { try write(nil) }
        try response()
    }

    func makeFolder(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let reply = try transact(0x100C, [storageID, rootAware(try handle(parent))],
                                 data: objectInfo(name: (path as NSString).lastPathComponent, size: 0, isFolder: true))
        handles[path] = reply[2]
    }

    func delete(_ item: PhoneItem) throws {
        try transact(0x100B, [item.handle, 0])                                          // DeleteObject
        handles[item.path] = nil
    }

    func rename(_ item: PhoneItem, to name: String) throws {
        var value = Data()
        value.appendString(name)
        try transact(0x9804, [item.handle, 0xDC07], data: value)                        // SetObjectPropValue
    }

    // MARK: Transport

    private struct Row {
        var name = "", isFolder = false, size: Int64 = 0, date = Date.distantPast, parent: UInt32 = 0, storage: UInt32 = 0
    }

    private func handle(_ path: String) throws -> UInt32 {
        if let handle = handles[path] { return handle }
        _ = try list((path as NSString).deletingLastPathComponent, hidden: true)       // learns the children's handles
        guard let handle = handles[path] else { throw MTPError("“\((path as NSString).lastPathComponent)” isn’t on the phone.") }
        return handle
    }

    /// Requests that take a parent use 0xFFFFFFFF for the storage root.
    private func rootAware(_ handle: UInt32) -> UInt32 { handle == 0 ? 0xFFFF_FFFF : handle }

    private func fetch(_ code: UInt16, _ params: [UInt32] = []) throws -> Data {
        var data = Data()
        try transact(code, params) { data.append($0) }
        return data
    }

    @discardableResult
    private func transact(_ code: UInt16, _ params: [UInt32] = [], data: Data? = nil,
                          receive: ((Data) throws -> Void)? = nil) throws -> [UInt32] {
        try command(code, params)
        if let data {
            let packet = header(length: 12 + data.count, type: 2, code: code) + data
            try write(packet)
            if packet.count % packetSize == 0 { try write(nil) }
        }
        return try response(receive)
    }

    private func command(_ code: UInt16, _ params: [UInt32] = []) throws {
        transaction += 1
        var packet = header(length: 12 + 4 * params.count, type: 1, code: code)
        params.forEach { packet.append(littleEndian: $0) }
        try write(packet)
    }

    private func header(length: Int, type: UInt16, code: UInt16) -> Data {
        var data = Data()
        data.append(littleEndian: UInt32(min(length, 0xFFFF_FFFF)))
        data.append(littleEndian: type)
        data.append(littleEndian: code)
        data.append(littleEndian: transaction)
        return data
    }

    private func write(_ data: Data?) throws {
        var sent = 0
        try output.__sendIORequest(with: data.map { NSMutableData(data: $0) }, bytesTransferred: &sent, completionTimeout: timeout)
    }

    /// Reads an optional data phase, handing it over in pieces, then the response.
    @discardableResult
    private func response(_ receive: ((Data) throws -> Void)? = nil) throws -> [UInt32] {
        var remaining = 0
        while true {
            var count = 0
            try input.__sendIORequest(with: buffer, bytesTransferred: &count, completionTimeout: timeout)
            guard count > 0 else { continue }                   // zero-length packet ends a data phase
            let bytes = buffer.bytes
            if remaining > 0 {
                let take = min(count, remaining)
                remaining -= take
                try receive?(Data(bytes: bytes, count: take))
                continue
            }
            let length = Int(bytes.loadUnaligned(as: UInt32.self))
            let type = bytes.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            let code = bytes.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
            if type == 2 {
                let take = min(count, length) - 12
                remaining = length - 12 - take
                try receive?(Data(bytes: bytes + 12, count: take))
            } else if type == 3 {
                guard code == 0x2001 || code == 0x201E else { throw Self.error(code) }   // OK, session already open
                return (0..<(min(count, length) - 12) / 4).map { bytes.loadUnaligned(fromByteOffset: 12 + 4 * $0, as: UInt32.self) }
            }
        }
    }

    private func objectInfo(name: String, size: Int64, isFolder: Bool) -> Data {
        var data = Data()
        data.append(littleEndian: storageID)
        data.append(littleEndian: UInt16(isFolder ? 0x3001 : 0x3000))       // format: association / undefined
        data.append(littleEndian: UInt16(0))                                // protection
        data.append(littleEndian: UInt32(min(size, 0xFFFF_FFFF)))
        data.append(littleEndian: UInt16(0))                                // thumb format
        for _ in 0..<7 { data.append(littleEndian: UInt32(0)) }             // thumb and image sizes, parent
        data.append(littleEndian: UInt16(isFolder ? 1 : 0))                 // association type
        data.append(littleEndian: UInt32(0))                                // association description
        data.append(littleEndian: UInt32(0))                                // sequence number
        data.appendString(name)
        for _ in 0..<3 { data.appendString("") }                            // created, modified, keywords
        return data
    }

    private static func error(_ code: UInt16) -> MTPError {
        switch code {
        case 0x2009: MTPError(String(localized: "The item is no longer on the phone."))
        case 0x200C: MTPError(String(localized: "The phone is out of space."))
        case 0x200F, 0x200D: MTPError(String(localized: "The phone didn’t allow this."))
        case 0x2019: MTPError(String(localized: "The phone is busy. Try again in a moment."))
        default: MTPError(String(localized: "The phone reported an error (\(String(code, radix: 16))).", comment: "MTP response code"))
        }
    }

    /// "20261002T234056" in the phone's local time.
    private static func date(_ string: String) -> Date {
        var parts = DateComponents()
        let digits = string.filter(\.isNumber).compactMap { Int(String($0)) }
        guard digits.count >= 14 else { return .distantPast }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        (parts.year, parts.month, parts.day) = (number(0..<4), number(4..<6), number(6..<8))
        (parts.hour, parts.minute, parts.second) = (number(8..<10), number(10..<12), number(12..<14))
        return Calendar.current.date(from: parts) ?? .distantPast
    }

    nonisolated private static func device(of service: io_service_t) -> io_registry_entry_t {
        var parent: io_registry_entry_t = 0
        IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
        return parent
    }

    nonisolated private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// Little-endian reader for MTP datasets.
private struct Reader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    mutating func u16() -> UInt16 { read() }
    mutating func u32() -> UInt32 { read() }
    mutating func u64() -> UInt64 { read() }

    mutating func u32Array() -> [UInt32] { (0..<u32()).map { _ in u32() } }

    mutating func string() -> String {
        let count = Int(read() as UInt8)
        let units = (0..<count).map { _ in u16() }.filter { $0 != 0 }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Skips a property value of an MTP data type.
    mutating func skip(_ type: UInt16) {
        switch type {
        case 0xFFFF: _ = string()
        case 0x4001...0x400A: let count = Int(u32()); offset += count * Self.width(type & 0xFF)
        default: offset += Self.width(type)
        }
    }

    private static func width(_ type: UInt16) -> Int {
        switch type { case 1, 2: 1; case 3, 4: 2; case 5, 6: 4; case 7, 8: 8; default: 16 }
    }

    private mutating func read<T: FixedWidthInteger>() -> T {
        guard offset + MemoryLayout<T>.size <= data.count else { offset = data.count; return 0 }
        defer { offset += MemoryLayout<T>.size }
        return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// MTP string: a length byte counting UTF-16 units including the terminator, then the units.
    mutating func appendString(_ string: String) {
        let units = Array(string.utf16)
        guard !units.isEmpty else { append(UInt8(0)); return }
        append(UInt8(units.count + 1))
        (units + [0]).forEach { append(littleEndian: $0) }
    }
}
