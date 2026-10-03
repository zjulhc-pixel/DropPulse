import AppKit
import ImageIO
import IOKit
import SwiftUI

enum ViewMode: String { case icons, list }

/// User preferences, shared with `@AppStorage` in SettingsView.
enum Prefs {
    static var importFolder: URL { folder("importFolder", .picturesDirectory, "Droplet") }
    static var copyFolder: URL { folder("copyFolder", .downloadsDirectory, nil) }
    static var showHidden: Bool { UserDefaults.standard.bool(forKey: "showHidden") }
    static var revealAfterCopy: Bool { UserDefaults.standard.object(forKey: "revealAfterCopy") as? Bool ?? true }
    static var openOnConnect: Bool { UserDefaults.standard.object(forKey: "openOnConnect") as? Bool ?? true }

    private static func folder(_ key: String, _ base: FileManager.SearchPathDirectory, _ sub: String?) -> URL {
        if let path = UserDefaults.standard.string(forKey: key) { return URL(filePath: path) }
        let url = FileManager.default.urls(for: base, in: .userDomainMask)[0]
        return sub.map { url.appending(path: $0) } ?? url
    }
}

@MainActor @Observable final class Transfer: Identifiable {
    enum State: Equatable { case waiting, running, done, cancelled, failed(String) }

    let id = UUID()
    let toMac: Bool
    let count: Int
    let destination: String
    var state = State.waiting
    var total: Int64 = 0
    var sent: Int64 = 0
    var current = ""
    var started = Date.now
    var finished: URL?             // first copied file, for "Show in Finder"
    var task: Task<Void, Never>?

    init(toMac: Bool, count: Int, destination: String) {
        self.toMac = toMac; self.count = count; self.destination = destination
    }

    var isActive: Bool { state == .waiting || state == .running }
    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : state == .done ? 1 : 0 }
    var speed: Double { Double(sent) / max(0.001, Date.now.timeIntervalSince(started)) }
    func cancel() { task?.cancel() }

    /// Called from the MTP queue for every chunk.
    nonisolated func advance(_ bytes: Int64) {
        Task { @MainActor in sent += bytes }
    }
}

@MainActor @Observable final class Store {
    static let shared = Store()
    static let cameraPath = "/DCIM/Camera"

    enum Phase: Equatable { case searching, locked, busy, connected }

    // Connection
    private(set) var phase = Phase.searching
    private(set) var device: MTP?
    private(set) var storage: Storage?
    private(set) var busyOwner: String?          // the app holding the phone, when it isn't us
    private var ejectedSerial: String?

    // Browsing
    private(set) var path = "/"
    private(set) var history: (back: [String], forward: [String]) = ([], [])
    private(set) var listings: [String: [PhoneItem]] = [:]
    private(set) var loading = false
    var selection = Set<String>()
    var search = ""
    var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .icons {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    private(set) var favorites = UserDefaults.standard.stringArray(forKey: "favorites")
        ?? ["/", cameraPath, "/Download"]
    private(set) var missing = Set<String>()        // favorites absent on this phone

    // Transfers and dialogs
    private(set) var transfers: [Transfer] = []
    private var transferTail: Task<Void, Never>?
    var previewURL: URL?
    var playing: PhoneItem?
    var alert: String?
    var confirmDelete: [PhoneItem]?
    var renaming: PhoneItem?
    var creatingFolder = false
    var replacePrompt: (count: Int, answer: CheckedContinuation<Bool?, Never>)?

    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Droplet")
    private var takenCache: [String: Double] = [:]
    private var dating = Set<String>()

    private init() {
        takenCache = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: takenFile))) ?? [:]
        Task { await monitor() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Store.shared.device?.closeNow() }
        }
    }

    // MARK: Connection

    var isConnected: Bool { phase == .connected }

    /// Looks for a phone while none is connected, waits for unlocking, refreshes free space.
    /// Unplugging is reported instantly by the USB interface itself.
    private func monitor() async {
        var tick = 0
        while true {
            switch phase {
            case .connected:
                if tick % 5 == 0, !transfers.contains(where: \.isActive), let device {
                    storage = (try? await device.storage()) ?? storage
                }
            case .locked:
                await loadStorage()
            case .searching, .busy:
                if let service = MTP.findInterface() {
                    let serial = MTP.serial(of: service)
                    // macOS's image capture daemon grabs phones as they're plugged in. It restarts on
                    // demand, so it is safe to stop; any other app is left alone and named instead.
                    if let owner = MTP.owner(of: service), owner.name != "Droplet" {
                        if owner.name == "ptpcamerad" {
                            kill(owner.pid, SIGKILL)
                            try? await Task.sleep(for: .milliseconds(200))
                        } else {
                            busyOwner = owner.name
                        }
                    }
                    if serial != ejectedSerial { await connect(service) }
                    IOObjectRelease(service)
                } else {
                    ejectedSerial = nil
                }
            }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func connect(_ service: io_service_t) async {
        do {
            device = try await MTP.connect(service) { Task { @MainActor in await Store.shared.disconnect() } }
            busyOwner = nil
            await loadStorage()
        } catch {
            phase = .busy                // another app holds the phone, or it isn't answering yet
        }
    }

    private func loadStorage() async {
        guard let device, let first = try? await device.storage() else { phase = .locked; return }
        storage = first
        if UserDefaults.standard.object(forKey: lastImportKey) == nil {
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastImportKey)
        }
        withAnimation(.smooth) { phase = .connected }
        await checkFavorites()
        open(missing.contains(Self.cameraPath) ? "/" : Self.cameraPath, record: false)
        if path != Self.cameraPath { await refresh(Self.cameraPath) }      // prefetch for "Import New"
    }

    private func disconnect() async {
        guard let device else { return }
        self.device = nil
        transfers.forEach { $0.cancel() }
        await device.close()
        withAnimation(.smooth) {
            phase = .searching
            storage = nil
            listings = [:]; selection = []; history = ([], []); path = "/"
        }
    }

    func eject() {
        ejectedSerial = device?.serial
        Task { await disconnect() }
    }

    // MARK: Browsing

    var items: [PhoneItem] {
        let all = listings[path] ?? []
        return search.isEmpty ? all : all.filter { $0.name.localizedStandardContains(search) }
    }

    var selectedItems: [PhoneItem] { items.filter { selection.contains($0.id) } }

    func open(_ newPath: String, record: Bool = true) {
        guard newPath != path || listings[newPath] == nil else { return }
        if record { history.back.append(path); history.forward = [] }
        path = newPath
        selection = []
        search = ""
        Task { await refresh(newPath) }
    }

    func goBack() {
        guard let previous = history.back.popLast() else { return }
        history.forward.append(path)
        open(previous, record: false)
    }

    func goForward() {
        guard let next = history.forward.popLast() else { return }
        history.back.append(path)
        open(next, record: false)
    }

    func goUp() {
        if path != "/" { open((path as NSString).deletingLastPathComponent) }
    }

    /// Cached listings show instantly; the phone is re-read in the background.
    func refresh(_ target: String? = nil) async {
        let target = target ?? path
        guard let device else { return }
        if listings[target] == nil, target == path { loading = true }
        defer { if target == path { loading = false } }
        do {
            let sorted = arrange(try await device.list(target, hidden: Prefs.showHidden))
            if listings[target] != sorted {
                withAnimation(listings[target] == nil ? nil : .snappy) { listings[target] = sorted }
            }
            if sorted.contains(where: { $0.kind == .image && $0.taken == nil }) { Task { await findTakenDates(target) } }
        } catch {
            if target == path { alert = error.localizedDescription }
        }
    }

    /// Folders by name, then files newest first by when they were taken.
    private func arrange(_ items: [PhoneItem]) -> [PhoneItem] {
        items.map { item in
            var item = item
            item.taken = Self.nameDate(item.name) ?? takenCache[Self.dateKey(item)].map(Date.init(timeIntervalSince1970:))
            return item
        }
        .sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.isFolder ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.shown > b.shown
        }
    }

    // MARK: Capture dates

    /// Imported photos (from a camera app, say) are modified when they reach the phone, so
    /// grouping by that date is wrong. Camera file names carry the time they were taken;
    /// otherwise it comes from the Exif block at the start of the file, read in the background
    /// and cached on the Mac.
    private func findTakenDates(_ path: String) async {
        guard let device, !dating.contains(path) else { return }
        dating.insert(path)
        defer { dating.remove(path) }
        let pending = (listings[path] ?? []).filter { $0.kind == .image && $0.taken == nil }
        for (index, item) in pending.enumerated() {
            guard let head = try? await device.read(item, length: 64 << 10) else { continue }
            takenCache[Self.dateKey(item)] = (Self.exifDate(head, size: item.size) ?? item.date).timeIntervalSince1970
            if index % 40 == 39 || index == pending.count - 1, let items = listings[path] {
                withAnimation(.snappy) { listings[path] = arrange(items) }
            }
        }
        try? JSONEncoder().encode(takenCache).write(to: takenFile)
    }

    private var takenFile: URL { cacheDir.appending(path: "taken.json") }

    private static func dateKey(_ item: PhoneItem) -> String { "\(item.path)|\(item.size)|\(item.date.timeIntervalSince1970)" }

    /// "IMG20260607175302", "IMG_20260502_162437", "Screenshot_2026-09-30-14-22-10".
    nonisolated static func nameDate(_ name: String) -> Date? {
        guard let match = name.firstMatch(of: /(20\d\d)[-_]?(\d\d)[-_]?(\d\d)[-_ T]?(\d\d)[-_.]?(\d\d)[-_.]?(\d\d)/),
              let month = Int(match.2), (1...12).contains(month), let day = Int(match.3), (1...31).contains(day),
              let hour = Int(match.4), hour < 24, let minute = Int(match.5), minute < 60, let second = Int(match.6), second < 60
        else { return nil }
        return Calendar.current.date(from: DateComponents(year: Int(match.1), month: month, day: day, hour: hour, minute: minute, second: second))
    }

    /// Exif DateTimeOriginal, with its time zone offset when the camera recorded one. ImageIO
    /// only needs the header, so the rest of the file stands in as zeros.
    nonisolated static func exifDate(_ head: Data, size: Int64) -> Date? {
        var sparse = Data(count: Int(max(size, Int64(head.count))))
        sparse.replaceSubrange(0..<head.count, with: head)
        guard let properties = CGImageSourceCreateWithData(sparse as CFData, nil)
                .flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssxxx"
        return format.date(from: text + (offset ?? ""))
    }

    func activate(_ item: PhoneItem) {
        switch item.kind {
        case .folder: open(item.path)
        case .video: playing = item
        default: preview(item)
        }
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    /// Finder-style click: plain selects, ⌘ toggles, ⇧ extends.
    func click(_ item: PhoneItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selection.formSymmetricDifference([item.id])
        } else if flags.contains(.shift), let anchor = items.firstIndex(where: { selection.contains($0.id) }),
                  let index = items.firstIndex(of: item) {
            selection.formUnion(items[min(anchor, index)...max(anchor, index)].map(\.id))
        } else {
            selection = [item.id]
        }
    }

    // MARK: Favorites

    var visibleFavorites: [String] { favorites.filter { !missing.contains($0) } }

    func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) { favorites.remove(at: index) } else { favorites.append(path) }
        UserDefaults.standard.set(favorites, forKey: "favorites")
        missing.remove(path)
    }

    private func checkFavorites() async {
        guard let device else { return }
        var absent = Set<String>()
        for path in favorites where path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            let names = (try? await device.list(parent, hidden: true).map(\.name)) ?? []
            if !names.contains((path as NSString).lastPathComponent) { absent.insert(path) }
        }
        missing = absent
    }

    // MARK: Import new photos

    private var lastImportKey: String { "lastImport-\(device?.serial ?? "")" }

    /// Starts at the first connection, so a new phone doesn't offer its whole camera roll.
    var lastImport: Date { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastImportKey)) }

    var newItems: [PhoneItem] {
        (listings[Self.cameraPath] ?? []).filter { !$0.isFolder && $0.date > lastImport }
    }

    func importNew() {
        let items = newItems
        guard let newest = items.map(\.date).max() else { return }
        let key = lastImportKey
        copyToMac(items, to: Prefs.importFolder) {
            UserDefaults.standard.set(newest.timeIntervalSince1970, forKey: key)
        }
    }

    // MARK: Phone → Mac

    func copyToMac(_ items: [PhoneItem], to folder: URL = Prefs.copyFolder, then: (() -> Void)? = nil) {
        // Same name and size already on the Mac: nothing to do.
        let todo = items.filter { item in
            let size = (try? folder.appending(path: item.name).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            return item.isFolder || size != item.size
        }
        guard let device, !todo.isEmpty else { then?(); return }
        enqueue(Transfer(toMac: true, count: todo.count, destination: folder.lastPathComponent)) { transfer in
            var files: [(item: PhoneItem, relative: String)] = []
            for item in todo {
                files.append((item, item.name))
                if item.isFolder { files += try await device.walk(item) }
            }
            transfer.total = files.reduce(0) { $0 + $1.item.size }
            // Copy into a staging folder on the same volume, then move with Finder-style
            // unique names, so nothing on the Mac is ever overwritten or left half-written.
            let stage = folder.appending(path: ".droplet-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            for (item, relative) in files {
                let target = stage.appending(path: relative)
                if item.isFolder {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    transfer.current = item.name
                    try await device.download(item, to: target, progress: transfer.advance)
                }
            }
            for file in try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
                let target = folder.uniqueChild(file.lastPathComponent)
                try FileManager.default.moveItem(at: file, to: target)
                transfer.finished = transfer.finished ?? target
            }
            then?()
            if Prefs.revealAfterCopy, let first = transfer.finished {
                NSWorkspace.shared.activateFileViewerSelecting([first])
            }
        }
    }

    func copyToMacChoosingFolder(_ items: [PhoneItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Copy Here")
        if panel.runModal() == .OK, let url = panel.url { copyToMac(items, to: url) }
    }

    /// Copies one item into the cache (for Quick Look, opening, and dragging to Finder).
    func fetch(_ item: PhoneItem) async throws -> URL {
        guard let device else { throw MTPError(String(localized: "The phone is disconnected.")) }
        let dir = cacheDir.appending(path: "files").appending(path: item.path.stableHash)
        let url = dir.appending(path: item.name)
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == item.size { return url }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if item.isFolder {
            for (child, relative) in try await device.walk(item) {
                let target = dir.appending(path: relative)
                if child.isFolder {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await device.download(child, to: target)
                }
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try await device.download(item, to: url)
        }
        return url
    }

    func preview(_ item: PhoneItem) {
        Task {
            do { previewURL = try await fetch(item) } catch { alert = error.localizedDescription }
        }
    }

    func openOnMac(_ item: PhoneItem) {
        Task {
            do { NSWorkspace.shared.open(try await fetch(item)) } catch { alert = error.localizedDescription }
        }
    }

    // MARK: Mac → Phone

    func sendToPhone(_ urls: [URL], to folder: String? = nil) {
        let folder = folder ?? path
        let urls = urls.filter { !$0.path.hasPrefix(cacheDir.path) }      // ignore our own drags
        guard let device, !urls.isEmpty else { return }
        Task {
            var urls = urls
            let existing = ((try? await device.list(folder, hidden: true)) ?? [])
                .filter { item in urls.contains { $0.lastPathComponent == item.name } }
            if !existing.isEmpty {
                let replace = await withCheckedContinuation { replacePrompt = (existing.count, $0) }
                replacePrompt = nil
                switch replace {
                case true?: for item in existing { try? await device.delete(item) }
                case false?: urls.removeAll { url in existing.contains { $0.name == url.lastPathComponent } }
                case nil: return
                }
            }
            guard !urls.isEmpty else { return }
            let name = folder == "/" ? device.name : (folder as NSString).lastPathComponent
            enqueue(Transfer(toMac: false, count: urls.count, destination: name)) { transfer in
                transfer.total = urls.reduce(0) { $0 + $1.totalSize }
                for url in urls {
                    transfer.current = url.lastPathComponent
                    try await device.upload(url, to: folder, progress: transfer.advance)
                }
                await self.refresh(folder)
            }
        }
    }

    func sendToPhoneChoosingFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Send to Phone")
        if panel.runModal() == .OK { sendToPhone(panel.urls) }
    }

    // MARK: Editing on the phone

    func delete(_ items: [PhoneItem]) {
        guard let device else { return }
        Task {
            do { for item in items { try await device.delete(item) } } catch { alert = error.localizedDescription }
            selection.subtract(items.map(\.id))
            await refresh()
        }
    }

    func rename(_ item: PhoneItem, to name: String) {
        guard let device, !name.isEmpty, name != item.name else { return }
        Task {
            do { try await device.rename(item, to: name) } catch { alert = error.localizedDescription }
            await refresh()
        }
    }

    func makeFolder(_ name: String) {
        guard let device, !name.isEmpty else { return }
        Task {
            do { try await device.makeFolder((path as NSString).appendingPathComponent(name)) }
            catch { alert = error.localizedDescription }
            await refresh()
        }
    }

    // MARK: Transfer queue

    var activeTransfer: Transfer? { transfers.last(where: \.isActive) }

    private func enqueue(_ transfer: Transfer, _ work: @escaping @MainActor (Transfer) async throws -> Void) {
        withAnimation(.snappy) { transfers.insert(transfer, at: 0) }
        let previous = transferTail
        transfer.task = Task {
            await previous?.value
            guard !Task.isCancelled else { transfer.state = .cancelled; return }
            transfer.state = .running
            transfer.started = .now
            do {
                try await work(transfer)
                transfer.state = .done
            } catch is CancellationError {
                transfer.state = .cancelled
            } catch {
                transfer.state = .failed(error.localizedDescription)
            }
            if transfers.count > 20 { transfers.removeLast(transfers.count - 20) }
        }
        transferTail = transfer.task
    }
}

extension URL {
    /// "IMG.jpg" → "IMG 2.jpg" when the name is taken, like Finder.
    func uniqueChild(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = appending(path: name), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Size of a file, or of everything inside a folder.
    var totalSize: Int64 {
        let files = FileManager.default.enumerator(at: self, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { (try? ($0 as? URL)?.resourceValues(forKeys: [.fileSizeKey]))?.fileSize } ?? []
        return Int64(files.reduce(0, +) + ((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }
}
