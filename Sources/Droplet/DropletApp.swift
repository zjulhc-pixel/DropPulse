import SwiftUI

@main
struct DropletApp: App {
    private let store = Store.shared

    var body: some Scene {
        Window("Droplet", id: "main") {
            RootView()
        }
        .defaultSize(width: 1120, height: 740)
        .commands { DropletCommands(store: store) }

        MenuBarExtra {
            MenuPanel()
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Always alive in the menu bar, so it also opens the window when a phone connects.
private struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow
    private var store = Store.shared

    var body: some View {
        Image(systemName: store.isConnected ? "drop.fill" : "drop")
            .onChange(of: store.isConnected) { _, connected in
                if connected, Prefs.openOnConnect {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
    }
}

private struct DropletCommands: Commands {
    let store: Store

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Folder") { store.creatingFolder = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Copy to Mac") { store.copyToMac(store.selectedItems) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Send to Phone…") { store.sendToPhoneChoosingFiles() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button("Move to Trash on Phone") { store.confirmDelete = store.selectedItems }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selection.isEmpty)
        }

        CommandGroup(before: .sidebar) {
            Picker("View", selection: Binding(get: { store.viewMode }, set: { store.viewMode = $0 })) {
                Text("as Icons").tag(ViewMode.icons).keyboardShortcut("1")
                Text("as List").tag(ViewMode.list).keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            Divider()
        }

        CommandMenu("Go") {
            Group {
                Button("Back") { store.goBack() }.keyboardShortcut("[")
                    .disabled(store.history.back.isEmpty)
                Button("Forward") { store.goForward() }.keyboardShortcut("]")
                    .disabled(store.history.forward.isEmpty)
                Button("Enclosing Folder") { store.goUp() }.keyboardShortcut(.upArrow)
                    .disabled(store.path == "/")
                Divider()
                ForEach(Array(store.favorites.enumerated()), id: \.element) { index, path in
                    Button(folderTitle(path, device: store.device?.name)) { store.open(path) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
            }
            .disabled(!store.isConnected)
        }

        CommandMenu("Device") {
            Group {
                Button("Import New Photos & Videos") { store.importNew() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(store.newItems.isEmpty)
                Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
                Button("Eject") { store.eject() }.keyboardShortcut("e")
            }
            .disabled(!store.isConnected)
        }
    }
}

struct SettingsView: View {
    @AppStorage("importFolder") private var importFolder = Prefs.importFolder.path
    @AppStorage("copyFolder") private var copyFolder = Prefs.copyFolder.path
    @AppStorage("revealAfterCopy") private var revealAfterCopy = true
    @AppStorage("openOnConnect") private var openOnConnect = true
    @AppStorage("showHidden") private var showHidden = false

    var body: some View {
        Form {
            Section {
                FolderPicker(title: "Import new photos to", path: $importFolder)
                FolderPicker(title: "Copy to Mac saves to", path: $copyFolder)
                Toggle("Show in Finder when copying finishes", isOn: $revealAfterCopy)
            }
            Section {
                Toggle("Open Droplet when a phone connects", isOn: $openOnConnect)
                Toggle("Show hidden files", isOn: $showHidden)
                    .onChange(of: showHidden) { Task { await Store.shared.refresh() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

private struct FolderPicker: View {
    let title: LocalizedStringKey
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.directoryURL = URL(filePath: path)
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            } label: {
                Label((path as NSString).lastPathComponent, systemImage: "folder")
            }
        }
    }
}
