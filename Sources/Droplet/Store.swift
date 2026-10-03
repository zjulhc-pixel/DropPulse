import AppKit
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
    enum State: Equatable { case waiting, running, done, failed(String) }

    let id = UUID()
    let toMac: Bool
    let count: Int
    let destination: String
    var state = State.waiting
    var progress: TransferProgress?
    var finished: URL?             // first copied file, for "Show in Finder"

    init(toMac: Bool, count: Int, destination: String) {
        self.toMac = toMac; self.count = count; self.destination = destination
    }

    var isActive: Bool { state == .waiting || state == .running }
    var fraction: Double {
        guard let p = progress, p.bulkFileSize.total > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(p.bulkFileSize.sent) / Double(p.bulkFileSize.total))
    }
}

@MainActor @Observable final class Store {
    static let shared = Store()
    static let cameraPath = "/DCIM/Camera"

    enum Phase: Equatable { case searching, locked, busy, connected }

    // Connection
    private(set) var phase = Phase.searching
    private(set) var device: DeviceInfo?
    private(set) var storage: Storage?
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
        ?? ["/", cameraPath, "/Download", "/DCIM/Screenshots", "/Pictures/Screenshots"]
    private(set) var missing = Set<String>()        // favorites absent on this phone

    // Transfers and dialogs
    private(set) var transfers: [Transfer] = []
    private var transferTail: Task<Void, Never>?
    var previewURL: URL?
    var alert: String?
    var confirmDelete: [PhoneItem]?
    var renaming: PhoneItem?
    var creatingFolder = false
    var replacePrompt: (count: Int, answer: CheckedContinuation<Bool?, Never>)?

    private let kalam = Kalam.shared
    private var sid: Int { storage?.Sid ?? 0 }
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Droplet")

    private init() {
        Task { await monitor() }
    }

    // MARK: Connection

    var isConnected: Bool { phase == .connected }

    /// One loop drives connecting, unlock detection, unplug detection and free-space refresh.
    private func monitor() async {
        var tick = 0
        while true {
            switch phase {
            case .connected:
                if let device, !USB.isPresent(serial: device.serial) { await disconnect() }
                else if tick % 5 == 0, !transfers.contains(where: \.isActive) {
                    storage = try? await kalam.storages().first ?? storage
                }
            case .locked:
                if let device, !USB.isPresent(serial: device.serial) { await disconnect() }
                else { await loadStorage() }
            case .searching, .busy:
                if let serial = ejectedSerial {
                    if !USB.isPresent(serial: serial) { ejectedSerial = nil }
                } else {
                    await connect()
                }
            }
            tick += 1
            try? await Task.sleep(for: .seconds(phase == .connected ? 1 : 1.5))
        }
    }

    private func connect() async {
        do {
            device = try await kalam.initialize()
            await loadStorage()
        } catch let error as KalamError {
            phase = ["ErrorMtpLockExists", "ErrorDeviceSetup", "ErrorMultipleDevice"].contains(error.type) ? .busy : .searching
        } catch {
            phase = .searching
        }
    }

    private func loadStorage() async {
        guard let first = try? await kalam.storages().first else { phase = .locked; return }
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
        await kalam.dispose()
        withAnimation(.smooth) {
            phase = .searching
            device = nil; storage = nil
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
        guard isConnected else { return }
        if listings[target] == nil, target == path { loading = true }
        defer { if target == path { loading = false } }
        do {
            let items = try await kalam.list(sid, target, hidden: Prefs.showHidden)
            let sorted = items.sorted { a, b in
                a.isFolder != b.isFolder ? a.isFolder : a.isFolder ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.date > b.date
            }
            if listings[target] != sorted {
                withAnimation(listings[target] == nil ? nil : .snappy) { listings[target] = sorted }
            }
        } catch {
            if target == path { alert = error.localizedDescription }
        }
    }

    func activate(_ item: PhoneItem) {
        if item.isFolder { open(item.path) } else { preview(item) }
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

    func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) { favorites.remove(at: index) } else { favorites.append(path) }
        UserDefaults.standard.set(favorites, forKey: "favorites")
        missing.remove(path)
    }

    private func checkFavorites() async {
        let others = favorites.filter { $0 != "/" }
        guard let found = try? await kalam.existing(sid, others) else { return }
        missing = Set(others).subtracting(found)
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
        guard !todo.isEmpty else { then?(); return }
        let sid = sid
        enqueue(Transfer(toMac: true, count: todo.count, destination: folder.lastPathComponent)) { [kalam] transfer in
            // Download into a staging folder on the same volume, then move with Finder-style
            // unique names so nothing on the Mac is ever overwritten.
            let stage = folder.appending(path: ".droplet-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            try await kalam.download(sid, todo.map(\.path), to: stage) { p in Task { @MainActor in transfer.progress = p } }
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

    /// Downloads one item into the cache (for Quick Look, opening, and dragging to Finder).
    func fetch(_ item: PhoneItem) async throws -> URL {
        let dir = cacheDir.appending(path: "files").appending(path: item.path.stableHash)
        let url = dir.appending(path: item.name)
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == item.size { return url }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await kalam.download(sid, [item.path], to: dir)
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
        guard isConnected, !urls.isEmpty else { return }
        Task {
            var urls = urls
            let targets = urls.map { (folder as NSString).appendingPathComponent($0.lastPathComponent) }
            let existing = (try? await kalam.existing(sid, targets)) ?? []
            if !existing.isEmpty {
                let replace = await withCheckedContinuation { replacePrompt = (existing.count, $0) }
                replacePrompt = nil
                switch replace {
                case true?: try? await kalam.delete(sid, Array(existing))
                case false?: urls = zip(urls, targets).filter { !existing.contains($0.1) }.map(\.0)
                case nil: return
                }
            }
            guard !urls.isEmpty else { return }
            let sid = sid
            let name = folder == "/" ? device?.name ?? "" : (folder as NSString).lastPathComponent
            enqueue(Transfer(toMac: false, count: urls.count, destination: name)) { [kalam] transfer in
                try await kalam.upload(sid, urls, to: folder) { p in Task { @MainActor in transfer.progress = p } }
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
        Task {
            do { try await kalam.delete(sid, items.map(\.path)) } catch { alert = error.localizedDescription }
            selection.subtract(items.map(\.id))
            await refresh()
        }
    }

    func rename(_ item: PhoneItem, to name: String) {
        guard !name.isEmpty, name != item.name else { return }
        Task {
            do { try await kalam.rename(sid, item.path, to: name) } catch { alert = error.localizedDescription }
            await refresh()
        }
    }

    func makeFolder(_ name: String) {
        guard !name.isEmpty else { return }
        Task {
            do { try await kalam.makeFolder(sid, (path as NSString).appendingPathComponent(name)) }
            catch { alert = error.localizedDescription }
            await refresh()
        }
    }

    // MARK: Transfer queue

    var activeTransfer: Transfer? { transfers.last(where: \.isActive) }

    private func enqueue(_ transfer: Transfer, _ work: @escaping @MainActor (Transfer) async throws -> Void) {
        withAnimation(.snappy) { transfers.insert(transfer, at: 0) }
        let previous = transferTail
        transferTail = Task {
            await previous?.value
            transfer.state = .running
            do {
                try await work(transfer)
                transfer.state = .done
            } catch {
                transfer.state = .failed(error.localizedDescription)
            }
            if transfers.count > 20 { transfers.removeLast(transfers.count - 20) }
        }
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
}

enum USB {
    /// Cheap IORegistry lookup, used to notice unplugging without touching the MTP session.
    static func isPresent(serial: String) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return true }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let value = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)
            if value?.takeRetainedValue() as? String == serial { return true }
        }
        return false
    }
}
