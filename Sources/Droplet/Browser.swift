import AVKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct Browser: View {
    @Bindable private var store = Store.shared
    @State private var dropping = false

    var body: some View {
        Group {
            switch store.viewMode {
            case .icons: GridBrowser()
            case .list: ListBrowser()
            }
        }
        .overlay {
            if store.items.isEmpty {
                if store.loading {
                    ProgressView()
                } else if !store.search.isEmpty {
                    ContentUnavailableView.search(text: store.search)
                } else {
                    ContentUnavailableView("Empty Folder", systemImage: "folder",
                                           description: Text("Drop files here to send them to your phone."))
                }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .overlay {
                        Label("Send to \(store.title)", systemImage: "arrow.up.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .glassEffect()
                    }
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if !store.selection.isEmpty {
                SelectionBar()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.selection.isEmpty)
        .animation(.snappy, value: dropping)
        .dropDestination(for: URL.self) { urls, _ in
            store.sendToPhone(urls)
            return true
        } isTargeted: { dropping = $0 }
        .quickLookPreview($store.previewURL)
        .sheet(item: $store.playing) { VideoSheet(item: $0) }
        .navigationTitle(store.title)
        .navigationSubtitle(store.subtitle)
        .searchable(text: $store.search, placement: .toolbar)
        .toolbar { BrowserToolbar() }
    }
}

private struct BrowserToolbar: ToolbarContent {
    @Bindable private var store = Store.shared

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { store.goBack() }
                .disabled(store.history.back.isEmpty)
            Button("Forward", systemImage: "chevron.right") { store.goForward() }
                .disabled(store.history.forward.isEmpty)
        }
        ToolbarItem {
            Picker("View", selection: $store.viewMode) {
                Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.icons)
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Button("Send to Phone…", systemImage: "arrow.up.circle") { store.sendToPhoneChoosingFiles() }
                .help("Send files from your Mac to this folder")
        }
        if !store.transfers.isEmpty {
            ToolbarItem { TransferButton() }
        }
        if !store.newItems.isEmpty {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { store.importNew() } label: {
                    Label("Import \(store.newItems.count) New", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .help("Copy new photos and videos to \(Prefs.importFolder.lastPathComponent)")
            }
        }
    }
}

// MARK: - Icon grid

private struct GridBrowser: View {
    private var store = Store.shared

    var body: some View {
        let items = store.items
        let files = items.filter { !$0.isFolder }
        let media = files.filter { $0.kind == .image || $0.kind == .video }.count
        let photoMode = !files.isEmpty && media * 5 >= files.count * 4

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if photoMode {
                    let folders = items.filter(\.isFolder)
                    if !folders.isEmpty { grid(folders, photo: false) }
                    ForEach(days(files), id: \.day) { group in
                        Section {
                            grid(group.items, photo: true)
                        } header: {
                            DayHeader(day: group.day, count: group.items.count)
                        }
                    }
                } else {
                    grid(items, photo: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 90)
            .dragContainer(for: PhoneItem.self) { ids in store.items.filter { ids.contains($0.id) } }
            .dragContainerSelection(Array(store.selection))
        }
        .contentShape(.rect)
        .onTapGesture { store.selection = [] }
        .focusable()
        .focusEffectDisabled()
        .onCommand(#selector(NSResponder.selectAll(_:))) { store.selectAll() }
        .onKeyPress(.space) { quickLook() }
        .onKeyPress(.return) { quickLook() }
    }

    private func grid(_ items: [PhoneItem], photo: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: photo ? 120 : 104, maximum: 200), spacing: photo ? 6 : 14, alignment: .top)],
                  spacing: photo ? 6 : 18) {
            ForEach(items) { item in
                Tile(item: item, photo: photo, selected: store.selection.contains(item.id))
                    .onTapGesture { store.click(item) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { store.activate(item) })
                    .draggable(containerItemID: item.id)
                    .contextMenu { ItemMenu(items: store.selection.contains(item.id) ? store.selectedItems : [item]) }
            }
        }
    }

    private func quickLook() -> KeyPress.Result {
        guard let item = store.selectedItems.first else { return .ignored }
        store.activate(item)
        return .handled
    }

    private func days(_ files: [PhoneItem]) -> [(day: Date, items: [PhoneItem])] {
        Dictionary(grouping: files) { Calendar.current.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }
}

private struct DayHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            Text(itemCount(count)).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.month(.wide).day().weekday(.wide) : .dateTime.year().month(.wide).day())
    }
}

private struct Tile: View {
    let item: PhoneItem
    let photo: Bool
    let selected: Bool

    var body: some View {
        if photo {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { Thumb(item: item, fill: true) }
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator.opacity(0.5)),
                                      lineWidth: selected ? 3 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.18), value: selected)
                .contentShape(.rect)
        } else {
            VStack(spacing: 6) {
                Thumb(item: item, fill: false)
                    .frame(width: 72, height: 72)
                    .padding(6)
                    .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
                Text(item.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(selected ? .white : .primary)
                    .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(.rect)
            .help(item.name)
        }
    }
}

/// Photo or video thumbnail, or the Mac's own icon for the file type.
struct Thumb: View {
    let item: PhoneItem
    var fill = false
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        if item.kind == .image || item.kind == .video {
            ZStack {
                if fill { Rectangle().fill(.quinary) }
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .clipShape(.rect(cornerRadius: fill ? 0 : 6))
                        .transition(.opacity)
                } else if !fill || failed {
                    Image(nsImage: Icons.for(item)).resizable().aspectRatio(contentMode: .fit)
                        .padding(fill ? 24 : 0)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Label(item.size.formatted(.byteCount(style: .file)), systemImage: "play.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .task(id: item) {
                let loaded = await Thumbs.shared.image(for: item)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                failed = loaded == nil && !Task.isCancelled
            }
        } else {
            Image(nsImage: Icons.for(item)).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

@MainActor enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func `for`(_ item: PhoneItem) -> NSImage {
        let key = item.isFolder ? "/" : item.ext
        if let icon = cache[key] { return icon }
        let type = item.isFolder ? UTType.folder : UTType(filenameExtension: item.ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}

// MARK: - List

private struct ListBrowser: View {
    @Bindable private var store = Store.shared
    @State private var order: [KeyPathComparator<PhoneItem>] = []

    var body: some View {
        let rows = order.isEmpty ? store.items : store.items.sorted(using: order)
        Table(of: PhoneItem.self, selection: $store.selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    Image(nsImage: Icons.for(item)).resizable().frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1)
                }
            }
            TableColumn("Date Modified", value: \.date) { item in
                Text(item.date, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 170)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : item.size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Kind") { item in
                Text(item.isFolder ? String(localized: "Folder")
                                   : UTType(filenameExtension: item.ext)?.localizedDescription ?? item.ext.uppercased())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140)
        } rows: {
            ForEach(rows) { TableRow($0).draggable($0) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ItemMenu(items: store.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let item = store.items.first(where: { ids.contains($0.id) }) { store.activate(item) }
        }
        .onKeyPress(.space) {
            guard let item = store.selectedItems.first else { return .ignored }
            store.preview(item)
            return .handled
        }
    }
}

// MARK: - Actions

private struct ItemMenu: View {
    let items: [PhoneItem]
    private var store = Store.shared

    init(items: [PhoneItem]) { self.items = items }

    var body: some View {
        if items.count == 1, let item = items.first {
            if item.isFolder {
                Button("Open") { store.open(item.path) }
                Button(store.isFavorite(item.path) ? "Remove from Sidebar" : "Add to Sidebar") { store.toggleFavorite(item.path) }
            } else {
                Button("Quick Look") { store.preview(item) }
                Button("Open on Mac") { store.openOnMac(item) }
            }
            Divider()
        }
        if !items.isEmpty {
            Button("Copy to Mac") { store.copyToMac(items) }
            Button("Copy to…") { store.copyToMacChoosingFolder(items) }
            Divider()
            if items.count == 1, let item = items.first {
                Button("Rename…") { store.renaming = item }
            }
            Button("Delete from Phone…", role: .destructive) { store.confirmDelete = items }
        }
        Divider()
        Button("New Folder") { store.creatingFolder = true }
    }
}

private struct SelectionBar: View {
    private var store = Store.shared

    var body: some View {
        let items = store.selectedItems
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(items.count) selected").fontWeight(.semibold)
                    Text(items.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                .glassEffect()

                Button("Copy to Mac", systemImage: "arrow.down.to.line") { store.copyToMac(items) }
                    .buttonStyle(.glassProminent)
                Button("Copy to…", systemImage: "folder") { store.copyToMacChoosingFolder(items) }
                    .labelStyle(.iconOnly).help("Copy to…")
                    .buttonStyle(.glass)
                Button("Delete from Phone…", systemImage: "trash", role: .destructive) { store.confirmDelete = items }
                    .labelStyle(.iconOnly).help("Delete from Phone…")
                    .buttonStyle(.glass)
                Button("Deselect", systemImage: "xmark") { store.selection = [] }
                    .labelStyle(.iconOnly).help("Deselect")
                    .buttonStyle(.glass)
            }
            .controlSize(.extraLarge)
        }
    }
}

/// Plays a phone video while it streams over USB; nothing is copied first.
private struct VideoSheet: View {
    let item: PhoneItem
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VideoPlayer(player: player)
            .frame(minWidth: 720, idealWidth: 960, minHeight: 405, idealHeight: 540)
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    .padding(12)
            }
            .onAppear {
                guard let device = Store.shared.device else { return }
                player = AVPlayer(playerItem: AVPlayerItem(asset: PhoneAsset(item, device)))
                player?.play()
            }
            .onDisappear { player?.pause() }
    }
}

// MARK: - Drag and drop

extension UTType {
    static let phoneItem = UTType(exportedAs: "app.droplet.phone-item")
}

extension PhoneItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .phoneItem)
        FileRepresentation(exportedContentType: .item) { item in
            SentTransferredFile(try await Store.shared.fetch(item))
        }
    }
}

func itemCount(_ n: Int) -> String {
    n == 1 ? String(localized: "1 item") : String(localized: "\(n) items")
}

extension Store {
    var title: String { folderTitle(path, device: device?.name) }

    var subtitle: String {
        let parent = path.split(separator: "/").dropLast().map { folderTitle(String($0), device: nil) }
        let count = itemCount((listings[path] ?? []).count)
        return parent.isEmpty ? count : parent.joined(separator: " › ") + " · " + count
    }
}
