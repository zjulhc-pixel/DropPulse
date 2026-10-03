import SwiftUI

struct RootView: View {
    @Bindable private var store = Store.shared
    @State private var newName = ""

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if store.isConnected { Browser() } else { ConnectView() }
        }
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
                ForEach(store.favorites.filter { !store.missing.contains($0) }, id: \.self) { path in
                    Label(folderTitle(path, device: nil), systemImage: folderSymbol(path))
                        .badge(path == Store.cameraPath && !store.newItems.isEmpty ? Text("\(store.newItems.count)") : nil)
                        .tag(path)
                        .dropDestination(for: URL.self) { urls, _ in store.sendToPhone(urls, to: path); return true }
                        .contextMenu {
                            Button("Remove from Sidebar") { store.toggleFavorite(path) }
                        }
                }
            }
            .disabled(!store.isConnected)

            Section("Mac") {
                ForEach(macFolders, id: \.self) { url in
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(FileManager.default.displayName(atPath: url.path), systemImage: macSymbol(url))
                    }
                    .buttonStyle(.plain)
                    .help("Drop phone items here to copy them")
                    .dropDestination(for: PhoneItem.self) { items, _ in store.copyToMac(items, to: url); return true }
                }
            }
        }
    }

    private var macFolders: [URL] {
        var folders = [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .picturesDirectory]
            .map { FileManager.default.urls(for: $0, in: .userDomainMask)[0] }
        for url in [Prefs.copyFolder, Prefs.importFolder] where !folders.contains(url) { folders.append(url) }
        return folders
    }

    private func macSymbol(_ url: URL) -> String {
        switch url.lastPathComponent {
        case "Desktop": "menubar.dock.rectangle"
        case "Downloads": "arrow.down.circle"
        case "Pictures": "photo.on.rectangle"
        default: "folder"
        }
    }
}

private struct DeviceCard: View {
    private var store = Store.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "smartphone")
                .font(.title3)
                .foregroundStyle(store.isConnected ? .white : .secondary)
                .frame(width: 34, height: 34)
                .background(store.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 9))
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
