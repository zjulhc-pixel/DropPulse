import SwiftUI

// MARK: - First connection

struct ConnectView: View {
    private var store = Store.shared

    var body: some View {
        VStack(spacing: 32) {
            HStack(spacing: 18) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 84, weight: .thin))
                Image(systemName: "ellipsis")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Image(systemName: "smartphone")
                    .font(.system(size: 64, weight: .thin))
            }
            .foregroundStyle(.primary.opacity(0.85))

            VStack(spacing: 8) {
                Text("Connect your Android phone").font(.largeTitle.bold())
                Text("Plug in a USB cable and your photos, videos and files show up here. Nothing to install on the phone.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(alignment: .top, spacing: 14) {
                Step(number: 1, title: "Plug in the cable",
                     detail: "Use a USB‑C cable that carries data. Charge-only cables won’t work.",
                     active: store.phase == .searching)
                Step(number: 2, title: "Unlock your phone",
                     detail: "Your Mac can’t read the phone’s storage while the screen is locked.",
                     active: store.phase == .locked)
                Step(number: 3, title: "Choose “File transfer”",
                     detail: "Pull down the notification shade, tap the USB option and switch to “File transfer”.",
                     active: store.phase == .searching)
            }
            .frame(maxWidth: 820)

            VStack(spacing: 12) {
                Label {
                    Text(status)
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .padding(.horizontal, 18).frame(height: 38)
                .glassEffect()
                Text("Still not detected? Quit apps that hold the USB connection, such as Android File Transfer or OpenMTP.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: store.phase)
    }

    private var status: LocalizedStringKey {
        switch store.phase {
        case .locked: "Waiting for you to unlock \(store.device?.name ?? "")…"
        case .busy: store.busyOwner.map { "“\($0)” is using the phone…" } ?? "Another app is using the phone…"
        default: "Waiting for a device…"
        }
    }
}

private struct Step: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number)")
                .font(.callout.bold()).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary), in: .circle)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(active ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.separator))
        }
    }
}

// MARK: - Transfers

struct TransferButton: View {
    private var store = Store.shared
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            if let active = store.activeTransfer {
                HStack(spacing: 6) {
                    ProgressView(value: active.fraction).progressViewStyle(.circular).controlSize(.small)
                    Text(active.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            } else {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
            }
        }
        .help("Transfers")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.transfers) { TransferRow(transfer: $0) }
                }
                .padding(18)
            }
            .frame(width: 360)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: transfer.toMac ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(.tint)
                Text(transfer.toMac ? "\(itemCount(transfer.count)) → \(transfer.destination)"
                                    : "\(itemCount(transfer.count)) → Phone › \(transfer.destination)")
                    .fontWeight(.medium).lineLimit(1)
                Spacer()
                if transfer.isActive {
                    Button("Stop", systemImage: "xmark.circle.fill") { transfer.cancel() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                } else if transfer.state == .done, let file = transfer.finished {
                    Button("Show in Finder", systemImage: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            switch transfer.state {
            case .waiting:
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
            case .running:
                ProgressView(value: transfer.fraction)
                HStack {
                    Text(transfer.current).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(transfer.sent.formatted(.byteCount(style: .file))) of \(transfer.total.formatted(.byteCount(style: .file))) · \(Int64(transfer.speed).formatted(.byteCount(style: .file)))/s")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            case .done:
                Text("Done").font(.caption).foregroundStyle(.secondary)
            case .cancelled:
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Menu bar

struct MenuPanel: View {
    @Environment(\.openWindow) private var openWindow
    private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(store.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.device?.name ?? String(localized: "No Device")).font(.headline)
                    if let storage = store.storage {
                        Text("USB connected · \(storage.free.formatted(.byteCount(style: .file))) free")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(store.phase == .locked ? "Unlock your phone" : "Plug in a USB cable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isConnected {
                    Button("Eject", systemImage: "eject.fill") { store.eject() }
                        .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                }
            }

            if store.isConnected {
                NewItemsCard()
            }

            if !store.transfers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Transfers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(store.transfers.prefix(3)) { TransferRow(transfer: $0) }
                }
            }

            HStack {
                Button("Open Droplet") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct NewItemsCard: View {
    private var store = Store.shared

    var body: some View {
        let items = store.newItems
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(items.isEmpty ? "No new photos" : "\(items.count) new photos & videos").font(.headline)
                Spacer()
                Text("Since \(store.lastImport.formatted(.dateTime.month().day()))").font(.caption).foregroundStyle(.secondary)
            }
            if !items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(items.prefix(5)) { item in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay { Thumb(item: item, style: .fill) }
                            .clipShape(.rect(cornerRadius: 7))
                    }
                }
                Button {
                    store.importNew()
                } label: {
                    Text("Import to \(Prefs.importFolder.lastPathComponent)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(14)
        .background(.background.secondary.opacity(0.6), in: .rect(cornerRadius: 18))
    }
}
