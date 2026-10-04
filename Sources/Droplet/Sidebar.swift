import SwiftUI

/// The sidebar's three states, stepped through by one toolbar button and ⌃⌘S.
enum SidebarMode: String {
    case full, icons, hidden

    var next: SidebarMode { self == .full ? .icons : self == .icons ? .hidden : .full }
    var symbol: String { self == .full ? "sidebar.left" : self == .icons ? "sidebar.squares.left" : "rectangle" }
    var title: LocalizedStringKey { self == .full ? "Show Sidebar" : self == .icons ? "Sidebar Icons Only" : "Hide Sidebar" }
}

struct RootView: View {
    @Bindable private var store = Store.shared
    @AppStorage("sidebarMode") private var mode = SidebarMode.full
    @State private var columns = UserDefaults.standard.string(forKey: "sidebarMode") == SidebarMode.hidden.rawValue
        ? NavigationSplitViewVisibility.detailOnly : .all
    @State private var newName = ""

    var body: some View {
        // Full and icons only are the same split view sidebar at two widths, so switching
        // between them is one continuous change of width; hidden collapses it.
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: SidebarWidth.icons, ideal: SidebarWidth.full, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if store.isConnected { Browser() } else { ConnectView() }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(mode.next.title, systemImage: mode.symbol) { mode = mode.next }
                        .help(mode.next.title)
                }
            }
        }
        .onChange(of: mode) { old, new in
            guard !SidebarWidth.followingUser else { SidebarWidth.followingUser = false; return }
            switch (old, new) {
            case (_, .hidden):
                withAnimation(.smooth) { columns = .detailOnly }
            case (.hidden, _):
                withAnimation(.smooth) { columns = .all }
                // AppKit brings the sidebar back at its last width; then settle at this mode's.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    SidebarWidth.animate(to: SidebarWidth.width(for: new), duration: 0.28, continuing: true)
                }
            default:
                SidebarWidth.animate(to: SidebarWidth.width(for: new))
            }
        }
        .onChange(of: columns) {
            // Dragged shut, or reopened by AppKit.
            if columns == .detailOnly, mode != .hidden { SidebarWidth.follow(.hidden) }
        }
        .onAppear {
            DispatchQueue.main.async {
                fitWindowToScreen()
                SidebarWidth.prepare()
                if mode == .icons { SidebarWidth.animate(to: SidebarWidth.icons, duration: 0) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in fitWindowToScreen() }
        .alert("Something went wrong", isPresented: Binding(get: { store.alert != nil }, set: { _ in store.alert = nil })) {
        } message: {
            Text(store.alert ?? "")
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { store.confirmDelete != nil }, set: { _ in store.confirmDelete = nil })) {
            Button("Delete", role: .destructive) { store.delete(store.confirmDelete ?? []) }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog(replaceTitle, isPresented: Binding(get: { store.replacePrompt != nil }, set: { _ in })) {
            Button("Replace") { store.replacePrompt?.answer.resume(returning: true) }
            Button("Skip") { store.replacePrompt?.answer.resume(returning: false) }
            Button("Cancel", role: .cancel) { store.replacePrompt?.answer.resume(returning: nil) }
        }
        .alert("New Folder", isPresented: $store.creatingFolder) {
            TextField("Name", text: $newName)
            Button("Create") { store.makeFolder(newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { store.renaming != nil }, set: { _ in store.renaming = nil })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let item = store.renaming { store.rename(item, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: store.renaming) { newName = store.renaming?.name ?? "" }
    }

    private var deleteTitle: String {
        let items = store.confirmDelete ?? []
        return items.count == 1 ? String(localized: "Delete “\(items[0].name)” from the phone?")
                                : String(localized: "Delete \(items.count) items from the phone?")
    }

    private var replaceTitle: String {
        String(localized: "\(store.replacePrompt?.count ?? 0) items with the same name already exist on the phone.")
    }
}

struct Sidebar: View {
    private var store = Store.shared
    @State private var width = SidebarWidth.full

    /// 1 with room for names, 0 at icon width; names fade in between as the sidebar resizes.
    private var names: Double { min(1, max(0, (width - 100) / 70)) }

    var body: some View {
        List(selection: Binding(get: { store.isFavorite(store.path) ? store.path : nil },
                                set: { if let path = $0 { store.open(path) } })) {
            if names > 0 {
                DeviceCard()
                    .opacity(names)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            Section {
                ForEach(store.visibleFavorites, id: \.self) { path in
                    let title = folderTitle(path, device: nil)
                    Label {
                        Text(title).lineLimit(1).opacity(names)
                    } icon: {
                        Image(systemName: folderSymbol(path))
                    }
                    .padding(.leading, (1 - names) * 7)          // centred once the names are gone
                    .badge(names > 0.6 && path == Store.cameraPath && !store.newItems.isEmpty ? Text("\(store.newItems.count)") : nil)
                    .help(title)
                    .tag(path)
                    .dropDestination(for: URL.self) { urls, _ in store.sendToPhone(urls, to: path); return true }
                    .contextMenu {
                        Button("Remove from Sidebar") { store.toggleFavorite(path) }
                    }
                }
            } header: {
                Text("Android").opacity(names)
            }
        }
        .animation(.smooth(duration: 0.2), value: names > 0)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            width = new
            SidebarWidth.userMayHaveResized()
        }
    }
}

/// Drives the sidebar's width directly on the AppKit split view, one display frame at a time,
/// since NavigationSplitView only reads its column width once.
@MainActor enum SidebarWidth {
    static let icons: CGFloat = 72
    static let full: CGFloat = 240
    static var followingUser = false              // the mode change came from a drag, not a command

    private static var link: CADisplayLink?
    private static var from: CGFloat = 0, to: CGFloat = 0, start: CFTimeInterval = 0, duration: CFTimeInterval = 0
    private static var continuing = false         // picks up a motion already under way: no slow start
    private static var settling: Task<Void, Never>?

    static func width(for mode: SidebarMode) -> CGFloat { mode == .icons ? icons : full }

    /// Lets the sidebar go down to icon width (SwiftUI asks AppKit for more).
    static func prepare() {
        (splitView()?.delegate as? NSSplitViewController)?.splitViewItems.first?.minimumThickness = icons
    }

    static func animate(to target: CGFloat, duration: CFTimeInterval = 0.32, continuing: Bool = false) {
        guard let split = splitView(), let current = currentWidth() else { return }
        prepare()
        link?.invalidate()
        (from, to, start, self.duration, self.continuing) = (current, target, CACurrentMediaTime(), duration, continuing)
        link = split.displayLink(target: Ticker.shared, selector: #selector(Ticker.tick))
        link?.add(to: .main, forMode: .common)
    }

    fileprivate static func step() {
        guard let split = splitView() else { link?.invalidate(); link = nil; return }
        let t = duration > 0 ? min(1, (CACurrentMediaTime() - start) / duration) : 1
        let eased = continuing ? 1 - pow(1 - t, 3) : t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        split.setPosition(from + (to - from) * eased, ofDividerAt: 0)
        if t >= 1 { link?.invalidate(); link = nil }
    }

    /// After a drag ends, snap to icons or to a comfortable width, and keep the mode in step.
    static func userMayHaveResized() {
        guard link == nil else { return }
        settling?.cancel()
        settling = Task {
            while NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(30)) }
            guard !Task.isCancelled, link == nil, let width = currentWidth() else { return }
            let compact = width < 150
            if compact, width != icons { animate(to: icons) }
            if !compact, width < 200 { animate(to: 200) }
            follow(compact ? .icons : .full)
        }
    }

    /// Records a mode the user arrived at by dragging, without replaying it as a command.
    static func follow(_ mode: SidebarMode) {
        guard UserDefaults.standard.string(forKey: "sidebarMode") != mode.rawValue else { return }
        followingUser = true
        UserDefaults.standard.set(mode.rawValue, forKey: "sidebarMode")
    }

    private static func currentWidth() -> CGFloat? {
        guard let split = splitView(), let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first,
              !item.isCollapsed else { return nil }
        return split.arrangedSubviews.first?.frame.width
    }

    private static func splitView() -> NSSplitView? {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.delegate is NSSplitViewController { return split }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.first { $0.identifier?.rawValue == "main" }?.contentView.flatMap(find)
    }
}

@MainActor private final class Ticker: NSObject {
    static let shared = Ticker()
    @objc func tick(_ link: CADisplayLink) { SidebarWidth.step() }
}

private struct DeviceCard: View {
    private var store = Store.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.device?.name ?? String(localized: "No Device")).font(.headline).lineLimit(1)
                if let storage = store.storage {
                    ProgressView(value: Double(storage.total - storage.free), total: Double(storage.total))
                        .controlSize(.mini)
                    Text("\(storage.free.formatted(.byteCount(style: .file))) free")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(store.phase == .locked ? "Unlock your phone" : "Plug in a USB cable")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if store.isConnected {
                Button("Eject", systemImage: "eject.fill") { store.eject() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Eject")
            }
        }
        .padding(.vertical, 6)
    }
}

/// A window saved on a taller screen can come back taller than this one, leaving its bottom
/// edge out of reach. Keep it within the screen.
@MainActor func fitWindowToScreen() {
    guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
          let visible = window.screen?.visibleFrame else { return }
    var frame = window.frame
    frame.size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
    frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
    if frame != window.frame { window.setFrame(frame, display: true, animate: true) }
}

func folderTitle(_ path: String, device: String?) -> String {
    if path == "/" { return device ?? String(localized: "Internal Storage") }
    let name = (path as NSString).lastPathComponent
    return Bundle.main.localizedString(forKey: name, value: name, table: "Folders")
}

func folderSymbol(_ path: String) -> String {
    switch (path as NSString).lastPathComponent {
    case "/": "internaldrive"
    case "Camera", "DCIM": "camera"
    case "Download", "Downloads": "arrow.down.circle"
    case "Screenshots": "camera.viewfinder"
    case "Pictures": "photo.on.rectangle"
    case "Movies": "film"
    case "Music": "music.note"
    case "Documents": "doc"
    default: "folder"
    }
}
