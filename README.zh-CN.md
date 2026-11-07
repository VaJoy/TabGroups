# TabGroups：仿 TrellisWM 的跨 app 标签组（Swift 原生小工具）

[English](README.md)

按住拖拽键（默认 ⌘），把一个窗口拖到另一个窗口的**中间**，停一下（约 0.35 秒）出现高亮，松手后两个窗口叠成一组，共用上方一条标签栏，不管它们属于哪个 app。
点标签切换；在栏内拖动标签可以排序；把标签拖出栏外就撕下来成为独立窗口；鼠标悬停时点 ✕ 关闭这个窗口；右键标签可以把它移出组，或解散当前分组（Ungroup All，只影响右键的这个组）。

按住 Shift 把窗口标题栏拖到另一个窗口或已有 workspace 的某个 pane 上，可以把最多 4 个跨 app 窗口拼成一个 workspace：拖 workspace 的左、下、右边缘或内部分割线会一起调整所有窗口；拖 pane 的任意边缘会先让子 app 自己缩放，松手后再提交：外边缘扩 workspace，内边缘更新分割比例，所有 pane 一起适配。双击 workspace 标题栏可铺满当前显示器；按住拖拽键把 workspace 标题栏拖到另一个窗口、另一个 workspace 的 pane 或分组标签条上，可以把整个 workspace 变成一个标签。双击标签栏里的标签名可以改名，清空则恢复默认。
打开 TabGroups（或在它运行时再打开一次）会显示一个 Liquid Glass 风格的设置窗口：拖拽键、切换标签键、「Launch at login」开机自启动（需要以 `TabGroups.app` 运行，`swift run` 时是灰的；开机自启动时不弹窗口）、「Show in Dock」是否显示 Dock 图标、检查和自动安装更新，以及「Quit TabGroups」退出按钮。

## 运行

需要 macOS 14 及以上和 Xcode 15 及以上（Swift 5.9）。

```bash
# 方式 A：直接跑（权限会挂在 Terminal / iTerm 上）
swift run

# 方式 B：打包成 .app（推荐，权限挂在 TabGroups.app 上）
chmod +x make-app.sh && ./make-app.sh && open build/TabGroups.app
```

`make-app.sh` 会用 Xcode 自带的 `actool` 编译 Liquid Glass 图标（`Support/AppIcon.icon`，可以用 Icon Composer 打开编辑）；只装了命令行工具时，app 会用通用图标。

第一次运行会弹出辅助功能授权，请到「系统设置 ▸ 隐私与安全性 ▸ 辅助功能」里勾选它。授权后无需重启，程序每秒检查一次，拿到权限就会开始工作。
程序不能放进沙盒：Accessibility API 在沙盒里不可用，所以它也上不了 Mac App Store。

默认没有 Dock 图标也没有菜单栏图标。退出时（再打开一次 app，在设置窗口点「Quit TabGroups」或按 ⌘Q；也可以在终端按 Ctrl-C，或 `pkill -INT TabGroups`）会先保存状态、解散所有组、释放所有 workspace，把窗口放回原位置。避免强制退出：拖动/缩放期间被临时停放的窗口可能留在屏幕角落。

## 文件

| 文件 | 作用 |
|---|---|
| `AX.swift` | Accessibility API 的封装、私有函数 `_AXUIElementGetWindow`、AX 坐标（左上原点）和 AppKit 坐标（左下原点）的互相转换 |
| `WindowTracker.swift` | 给每个 app 建一个 `AXObserver`，维护「CGWindowID → 窗口」表；用 `CGWindowListCopyWindowInfo` 按真实层级找出光标下面的窗口 |
| `DragController.swift` | 全局监听鼠标事件；判断标题栏拖动、分组/workspace 投放目标和高亮；事件 tap 负责任意位置拖动、workspace 子窗口边缘拦截和切换标签快捷键 |
| `GroupManager.swift` | 标签组模型：合并、切换、隐藏标签叠放/拖动时临时停放、撕下、跟随移动、解散、标签改名、持久化 |
| `ContainerLayout.swift` | workspace 的二叉分割树，最多 4 个 pane，带最小尺寸约束 |
| `Container.swift` | 一个 workspace：子窗口、AX 布局、分割线、激活与释放 |
| `ContainerWindow.swift` | workspace 外壳：标题栏、边缘缩放手柄、分割线命中区、双击标题栏铺满 |
| `ContainerManager.swift` | 创建/插入/移除 workspace，维护子窗口映射，保存和恢复 |
| `TabStrip.swift` | 标签栏：一个不会抢焦点的 `NSPanel`，负责绘制、点击、拖动排序、撕下时跟随光标的小卡片、双击改名编辑框 |
| `Settings.swift` | 设置窗口：拖拽/切换键、登录项、Dock 图标、更新、退出 |
| `Updates.swift` | Sparkle 更新：定时检查、自动下载、appcast |
| `App.swift` | 入口、辅助功能授权提示、SIGINT/SIGTERM 有序退出 |

## 已知限制

- 平时隐藏的标签是叠在当前标签后面的；拖动/缩放当前标签时，它们会被临时停放到屏幕角落，露出 1 像素。在 Mission Control 里也会显示，退出 Mission Control 时能看到它飞回右下角。如果程序崩溃没来得及恢复，可以在那个 app 里用「窗口 ▸ 缩放」或 Mission Control 把它找回来。
- 最小化当前标签，或最小化 workspace 里的子窗口，会让它离开所在的组/workspace。
- 正常退出（设置窗口退出、⌘Q、Ctrl-C）会保存分组和 workspace，下次启动会尽量恢复；崩溃或强制退出不会保存，工作区里的窗口会留在原地。
- workspace 只是把各 app 的真实窗口按比例摆在一个壳里，子窗口仍保留自己的标题栏、圆角和阴影，不是真正的单窗口。
- 拖 pane 边缘会先让子 app 自己缩放；松手后外边缘扩到 workspace，内边缘更新分割比例，所有 pane 重新适配；workspace 标题栏下面那条 pane 上边缘会回弹。普通单击不受影响，子 app 自己的 resize 光标可能仍会出现。
- 对全屏窗口、原生标签窗口（Finder / Safari 的 `AXTabGroup`）、对话框和 sheet 没有专门处理。
- `order(.above, relativeTo:)` 用的是其他 app 的窗口编号。如果遇到某个 app 的标签栏被它的窗口盖住，可以在 `windowFocused` 里加一次延迟后再重新排一次层级。

## 开源协议

[MIT](LICENSE)。例外：`site/public/macbook-pro.webp` 是 Apple 的 MacBook Pro 产品样机图，按 Apple Design Resources 许可使用，不在 MIT 协议范围内，不能单独再分发。
