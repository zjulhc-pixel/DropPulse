# Droplet

在 Mac 和 Android 手机之间传文件的原生 macOS App。界面用 SwiftUI 和 Liquid Glass 实现，USB/MTP 通信复用了 [OpenMTP](https://github.com/ganeshrvel/openmtp) 的 Kalam 内核。

## 构建

只装 Command Line Tools 就能构建，不需要 Xcode。系统要求 macOS 26 及以上，Apple 芯片。

```bash
./build.sh
open build/Droplet.app
```

## 功能

- **连接**：插上手机后自动连接，拔掉后自动断开。手机锁屏时会提示先解锁，解锁后自动继续。
- **浏览**：
  - 相机这类以照片、视频为主的文件夹，用照片网格显示，并按日期分组；其他文件夹用图标显示，也可以切换成可排序的列表。
  - 读过的文件夹会缓存下来，再次打开时立即显示，后台再刷新。
- **缩略图**：只加载屏幕上可见的照片，滚出屏幕的请求自动取消；生成过的缩略图存在磁盘上，下次直接用。
- **手机 → Mac**：
  - 支持选择栏、右键菜单、拖到 Finder，或拖到边栏里的 Mac 文件夹。
  - 不会覆盖 Mac 上已有的文件：同名且大小相同的直接跳过；同名但内容不同的会自动改名，比如 `IMG 2.jpg`。
- **Mac → 手机**：把文件拖进窗口，或拖到边栏里的 Android 文件夹即可发送。遇到同名文件时可以选择替换或跳过。
- **导入新照片**：第一次连接时记下当时的时间，之后新拍的照片和视频可以一键导入到“图片/Droplet”。工具栏、菜单栏面板和快捷键 ⇧⌘I 都能触发。
- **其他**：
  - 按空格键快速查看文件。
  - 可以在手机上新建文件夹、重命名和删除。
  - 菜单栏面板可以查看设备状态、导入新照片、查看最近的传输记录。

## 代码结构

| 文件 | 作用 |
| --- | --- |
| `Kalam.swift` | Kalam C 接口的桥接层和数据模型。所有调用都放在同一个串行队列里执行。 |
| `Store.swift` | 应用状态：连接、浏览、传输队列、文件操作。 |
| `Thumbs.swift` | 按需批量生成缩略图，并缓存到磁盘。 |
| `Browser.swift` | 网格视图、列表视图、浮动选择栏、拖放。 |
| `Sidebar.swift` | 窗口根视图、边栏、对话框。 |
| `Panels.swift` | 首次连接页、传输进度、菜单栏面板。 |
| `DropletApp.swift` | 场景、菜单命令、设置。 |

## 致谢与许可

- `Vendor/kalam/kalam.dylib`：来自 OpenMTP 3.3.0 的 Kalam 内核，© Ganesh Rathinavel，MIT 许可。
- `Vendor/kalam/libusb.dylib`：libusb，LGPL-2.1 许可，以动态链接方式使用。
