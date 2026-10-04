import SwiftUI

/// The sidebar's three states, stepped through by one toolbar button and ⌃⌘S.
enum SidebarMode: String {
    case full, icons, hidden

    var next: SidebarMode { self == .full ? .icons : self == .icons ? .hidden : .full }
    var symbol: String { self == .full ? "sidebar.left" : self == .icons ? "sidebar.squares.left" : "rectangle" }
    var title: LocalizedStringKey { self == .full ? "Show Sidebar" : self == .icons ? "Sidebar Icons Only" : "Hide Sidebar" }
}

struct RootView: View {
    static let motion = Animation.spring(duration: 0.45, bounce: 0.22)
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
            // The rail floats over the content, which makes room with the same animation, so
            // nothing jumps when it comes and goes.
            Group {
                if store.isConnected { Browser() } else { ConnectView() }
            }
            .padding(.leading, mode == .icons ? IconRail.width : 0)
            .overlay(alignment: .topLeading) {
                if mode == .icons {
                    IconRail()
                        .padding(.leading, 8)
                        .padding(.top, 8)
                        // Grows out of the corner where the sidebar button sits, like a glass
                        // button opening into a panel.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.2, anchor: .topLeading).combined(with: .opacity),
                            removal: .scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity)))
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(mode.next.title, systemImage: mode.symbol) { withAnimation(Self.motion) { mode = mode.next } }
                        .help(mode.next.title)
                }
            }
        }
        .onChange(of: mode) { withAnimation(Self.motion) { columns = mode == .full ? .all : .detailOnly } }
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

/// The sidebar folded down to its icons: a floating glass island beside the content. The
/// current folder sits under a glass lens that stretches across to a new pick, then springs
/// into place.
private struct IconRail: View {
    static let width: CGFloat = 8 + 56 + 10           // inset, island, gap before the content
    private static let cell: CGFloat = 44, gap: CGFloat = 4, inset: CGFloat = 6

    private var store = Store.shared
    @State private var lens: ClosedRange<Int>?        // rows the lens covers; both ends while moving
    @State private var hovered: String?
    @State private var hoveringIsland = false

    var body: some View {
        let favorites = store.visibleFavorites
        let current = favorites.firstIndex(of: store.path)
        VStack(spacing: Self.gap) {
            ForEach(favorites, id: \.self) { path in
                let title = folderTitle(path, device: nil)
                let selected = store.path == path
                Button(title, systemImage: folderSymbol(path)) { store.open(path) }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                    .scaleEffect(selected ? 1.12 : hovered == path ? 1.06 : 1)     // the lens magnifies
                    .frame(width: Self.cell, height: Self.cell)
                    .contentShape(.capsule)
                    .overlay(alignment: .topTrailing) {
                        if path == Store.cameraPath && !store.newItems.isEmpty {
                            Circle().fill(.tint).frame(width: 7, height: 7).offset(x: -6, y: 6)
                        }
                    }
                    .onHover { hovered = $0 ? path : (hovered == path ? nil : hovered) }
                    .help(title)
                    .dropDestination(for: URL.self) { urls, _ in store.sendToPhone(urls, to: path); return true }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.4, bounce: 0.35), value: store.path)
        .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: hovered)
        .padding(Self.inset)
        .background(alignment: .top) {
            if let lens {
                Color.clear
                    .frame(width: Self.cell, height: CGFloat(lens.count) * Self.cell + CGFloat(lens.count - 1) * Self.gap)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .offset(y: Self.inset + CGFloat(lens.lowerBound) * (Self.cell + Self.gap))
            }
        }
        .background { GlassIsland(lifted: hoveringIsland) }
        .onHover { hoveringIsland = $0 }
        .onAppear { lens = current.map { $0...$0 } }
        .onChange(of: current) { old, new in
            guard let new else { withAnimation(.smooth(duration: 0.25)) { lens = nil }; return }
            guard let old, old != new, lens != nil else {
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) { lens = new...new }
                return
            }
            // Stretch over both rows, then let go of the old one with a bounce.
            withAnimation(.easeIn(duration: 0.13)) { lens = min(old, new)...max(old, new) }
            Task {
                try? await Task.sleep(for: .milliseconds(130))
                withAnimation(.spring(duration: 0.45, bounce: 0.35)) { lens = new...new }
            }
        }
    }
}

/// A capsule of thick glass: a faint diagonal sheen, a darker top and brighter bottom inside
/// the edge, a specular rim that turns as the pointer arrives, and a soft shadow below.
private struct GlassIsland: View {
    var lifted: Bool

    var body: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.05), .white.opacity(lifted ? 0.24 : 0.18), .white.opacity(0.05)],
                                              startPoint: lifted ? .top : .topLeading, endPoint: lifted ? .bottom : .bottomTrailing))
            }
            .overlay {
                // Inner shading: dark along the top, light along the bottom.
                Capsule().strokeBorder(.black.opacity(0.07), lineWidth: 3).blur(radius: 2).offset(y: 1.5).mask(Capsule())
                Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 3).blur(radius: 2).offset(y: -1.5).mask(Capsule())
            }
            .overlay {
                Capsule().strokeBorder(
                    AngularGradient(stops: [.init(color: .white.opacity(0.95), location: 0), .init(color: .white.opacity(0.15), location: 0.18),
                                            .init(color: .white.opacity(0.15), location: 0.32), .init(color: .white.opacity(0.8), location: 0.5),
                                            .init(color: .white.opacity(0.15), location: 0.68), .init(color: .white.opacity(0.15), location: 0.82),
                                            .init(color: .white.opacity(0.95), location: 1)],
                                    center: .center, angle: .degrees(lifted ? -125 : -75)),
                    lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            .shadow(color: .black.opacity(lifted ? 0.16 : 0.2), radius: lifted ? 6 : 9, y: lifted ? 4 : 7)
            .scaleEffect(lifted ? 0.985 : 1)
            .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: lifted)
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
