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
    @State private var columns = UserDefaults.standard.string(forKey: "sidebarMode") ?? "full" == "full"
        ? NavigationSplitViewVisibility.all : .detailOnly
    @State private var newName = ""

    var body: some View {
        // Full is the split view's sidebar; icons only hides it and shows a glass rail inside
        // the content; hidden shows neither.
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(alignment: .top, spacing: 0) {
                if mode == .icons {
                    IconRail()
                        .padding(.leading, 10)
                        .padding(.top, 8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if store.isConnected { Browser() } else { ConnectView() }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(mode.next.title, systemImage: mode.symbol) { mode = mode.next }
                        .help(mode.next.title)
                }
            }
        }
        .onChange(of: mode) { withAnimation(.snappy) { columns = mode == .full ? .all : .detailOnly } }
        .onChange(of: columns) {
            // The sidebar can also be dragged shut or open.
            if columns == .all, mode != .full { mode = .full }
            if columns == .detailOnly, mode == .full { mode = .hidden }
        }
        .onAppear { DispatchQueue.main.async(execute: fitWindowToScreen) }
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

    var body: some View {
        List(selection: Binding(get: { store.isFavorite(store.path) ? store.path : nil },
                                set: { if let path = $0 { store.open(path) } })) {
            DeviceCard()
                .listRowSeparator(.hidden)
                .selectionDisabled()

            Section("Android") {
                ForEach(store.visibleFavorites, id: \.self) { path in
                    Label(folderTitle(path, device: nil), systemImage: folderSymbol(path))
                        .badge(path == Store.cameraPath && !store.newItems.isEmpty ? Text("\(store.newItems.count)") : nil)
                        .tag(path)
                        .dropDestination(for: URL.self) { urls, _ in store.sendToPhone(urls, to: path); return true }
                        .contextMenu {
                            Button("Remove from Sidebar") { store.toggleFavorite(path) }
                        }
                }
            }
        }
    }
}

/// The sidebar folded down to its icons: a floating glass column beside the content.
private struct IconRail: View {
    private var store = Store.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.visibleFavorites, id: \.self) { path in
                let title = folderTitle(path, device: nil)
                Button(title, systemImage: folderSymbol(path)) { store.open(path) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(store.path == path ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .circle)
                    .foregroundStyle(store.path == path ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .overlay(alignment: .topTrailing) {
                        if path == Store.cameraPath && !store.newItems.isEmpty {
                            Circle().fill(.tint).frame(width: 8, height: 8).offset(x: -4, y: 4)
                        }
                    }
                    .help(title)
                    .dropDestination(for: URL.self) { urls, _ in store.sendToPhone(urls, to: path); return true }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
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
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(store.phase == .locked ? "Unlock your phone" : "Plug in a USB cable")
                        .font(.caption).foregroundStyle(.secondary)
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
