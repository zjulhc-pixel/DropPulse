# Droplet

English · [中文](README.zh-CN.md)

A native macOS app for moving photos, videos and files between an Android phone and a Mac over USB. Built with SwiftUI and Liquid Glass, with a small MTP implementation written directly on Apple's IOUSBHost framework — no third-party libraries, no kernel extensions, nothing to install on the phone.

![Droplet](docs/hero.jpg)

## Why

Android File Transfer is gone and the alternatives feel dated. Droplet aims to feel like a first-party Mac app: plug the phone in, see your photos instantly, drag them out.

## Highlights

- **Fast browsing** — a whole folder is read in one MTP request (`GetObjectPropList`): 1,956 camera items in 0.4 s.
- **Instant thumbnails** — reads only the first 128 KB of each photo to pull the JPEG thumbnail the camera embeds in its Exif block (~2 ms each). HEIC files from cameras like Hasselblad use their HEIF preview item; JPEGs fall back to MTP `GetThumb`; videos read just their index and first frame.
- **Stream videos** — play phone videos while they stream over USB; nothing is copied first.
- **Safe copies** — never overwrites anything on the Mac: identical files are skipped, others get Finder-style names (`IMG 2.jpg`). Transfers are chunked, cancellable, and browsing keeps working while they run.
- **Grouped by capture date** — from camera file names, or Exif `DateTimeOriginal` read in the background and cached.
- **Liquid Glass UI** — a floating glass sidebar island whose selection lens stretches and springs between folders; a menu bar panel for new photos and recent transfers.
- **Opens when you plug in** — waits in the menu bar after login and opens its window when a phone connects. It also takes the phone back from macOS's `ptpcamerad`, which otherwise grabs MTP devices.

## Requirements

- macOS 26 or later, Apple silicon
- An Android phone set to **File transfer** mode, unlocked

## Build

Only the Command Line Tools are needed — no Xcode:

```bash
./build.sh
open build/Droplet.app
```

Copy `build/Droplet.app` to `/Applications` to have it start at login (it only registers itself as a login item from there).

## How it works

| File | What it does |
| --- | --- |
| `MTP.swift` | A small MTP initiator on IOUSBHost: session recovery, folder listings, ranged reads, chunked downloads, streamed uploads, rename, delete. It runs on its own serial queue so blocking USB I/O never stalls Swift's thread pool. |
| `Thumbs.swift` | Thumbnails from Exif / HEIF previews / GetThumb, video frames, and an `AVAssetResourceLoader` that streams video over ranged reads. |
| `Store.swift` | App state: connection, browsing, capture dates, the transfer queue, file operations. |
| `Browser.swift` | Photo grid and list, the floating selection bar, drag and drop, the video player. |
| `Sidebar.swift` | Window root, the sidebar and its glass island, dialogs. |
| `Panels.swift` | Connect guide, transfer progress, menu bar panel. |
| `DropletApp.swift` | Scenes, menu commands, settings, login item. |

The app and menu bar icons are drawn as vectors by `scripts/make-icon.swift`.

## Notes

- Tested with an OPPO Find X9 Ultra (ColorOS). Other Android phones speak the same MTP dialect, but reports are welcome.
- Only one app can use the phone over MTP at a time; quit Android File Transfer or OpenMTP while Droplet is connected.

## Credits

Inspired by [OpenMTP](https://github.com/ganeshrvel/openmtp) by Ganesh Rathinavel; the first prototype used its Kalam kernel. The current code contains no OpenMTP code. Design references: "Liquid glass" by Andrii Vynarchyk (Dribbble) and "Glass Button UI" by Rishabh Rai (Webflow).

## License

[MIT](LICENSE)
