# TabGroups

Cross-app window tabs for macOS, as a small native Swift app. Drop one window onto the middle of another, pause for a moment, and the two stack under a single strip of tabs, whichever apps they belong to. Inspired by the Tab groups feature of [TrellisWM](https://trelliswm.app).

[简体中文](README.zh-CN.md)

## What it does

- **Group:** hold the drag key (⌘ by default) and drag a window—by its title bar or any spot—onto the middle of another window (or onto a group's strip) and hold still for about 0.35 s. A highlight appears; let go and they become tabs. Dropping a grouped window brings its whole group along.
- **Switch:** click a tab. The shown tab fills the group's frame; the others stay stacked behind it (and are briefly parked off screen while the shown tab is moved or resized).
- **Reorder:** drag a tab along the strip.
- **Tear off:** drag a tab more than 24 px off the strip. It becomes its own window again, at the size it had before it joined.
- **Close:** hover a tab and click ✕.
- **Context menu:** right-click a tab for *Remove from Group* or *Ungroup All* (this group only).
- **Workspaces:** hold Shift and drag a window by its title bar onto another window, or onto a pane of an existing workspace, to tile up to four windows from different apps in one frame. Drag the workspace's left, bottom or right edge, or a splitter line, to resize the panes together; dragging any pane edge lets its app resize first, then commits on release (an outer edge resizes the workspace, an inner edge updates the splitter ratio), and every pane re-layouts. Double-click a workspace header to fill the current display; drag its header to move it. Hold the drag key and drag a workspace header onto another window, another workspace pane, or a group's strip to add the whole workspace as a tab.
- **Rename tabs:** double-click a tab title, type a new name and press Return; an empty name restores the default.
- **Settings window:** opening TabGroups (or opening it again while it runs) shows a small Liquid Glass window with the drag key, switch-tab key, *Launch at login*, *Show in Dock*, update check/install, and *Quit TabGroups*. *Launch at login* registers the app as a login item, so it needs `TabGroups.app`; a launch at login stays out of sight.
- The strip follows its window live while you move or resize it, makes room for itself when macOS tiles the window to a screen edge, and is hidden in Mission Control.

## Requirements

- macOS 14 or later, Swift 5.9 or later (Xcode 15+ or the command-line tools).
- Accessibility permission. The app moves other apps' windows through the Accessibility API, which doesn't work in a sandbox, so it can't ship on the Mac App Store.

## Build and run

```bash
# A: run from the terminal (the Accessibility grant goes to your terminal app)
swift run

# B: build an app bundle (the grant goes to TabGroups.app)
./make-app.sh && open build/TabGroups.app
```

On first launch macOS asks for Accessibility access: tick TabGroups (or your terminal) in **System Settings ▸ Privacy & Security ▸ Accessibility**. The app checks every second and starts as soon as it's allowed; no restart needed. `make-app.sh` signs ad hoc, so the grant may need re-ticking after each rebuild. It compiles the Liquid Glass app icon (`Support/AppIcon.icon`, an Icon Composer file) with `actool`, which comes with Xcode; with only the command-line tools the app gets a generic icon.

## Quitting

By default TabGroups has no Dock icon and no menu-bar item. Open it again to bring up its window and click **Quit TabGroups** (or press ⌘Q there); Ctrl-C in its terminal and `pkill -INT TabGroups` work too. Every group is dissolved and every workspace released first, the windows are put back, and the state is saved for the next launch. Avoid *Force Quit*: it leaves temporarily parked windows in the corner (bring them back with the app's *Window ▸ Zoom* or Mission Control).

## How it works

| File | Role |
|---|---|
| `AX.swift` | Accessibility helpers, the private `_AXUIElementGetWindow` (AX element → `CGWindowID`), conversion between AX (top-left) and AppKit (bottom-left) coordinates |
| `WindowTracker.swift` | One `AXObserver` per app; a table of standard windows; hit-testing in real z-order via `CGWindowListCopyWindowInfo` |
| `DragController.swift` | Global mouse monitors; title-bar drag detection from the WindowServer frame; group/workspace drop targets and highlight; the event tap for press-anywhere moves, workspace edge blocking and switch shortcuts |
| `GroupManager.swift` | The group model: join, switch, park, tear off, follow moves/resizes and edge tiling, ungroup, tab rename, and persistence for groups and workspaces |
| `ContainerLayout.swift` | Binary split tree for up to four workspace panes, with minimum pane sizes |
| `Container.swift` | A workspace: child windows, AX layout, splitters, activation and release |
| `ContainerWindow.swift` | The workspace shell: header, edge handles, splitter hit areas, header double-click zoom |
| `ContainerManager.swift` | Creates/inserts/removes workspaces, maps child windows, saves/restores them |
| `TabStrip.swift` | The strip: a non-activating panel ordered just above the shown window; drawing, clicks, reorder, tear-off chip, context menu, upward shadow, double-click rename editor |
| `Settings.swift` | Settings window: drag/switch keys, login item, Dock icon, update controls, quit |
| `Updates.swift` | Sparkle updater (scheduled checks, automatic download, appcast) |
| `App.swift` | Entry point, permission prompt, SIGINT/SIGTERM → orderly quit |

"Parking" moves a window so that a single pixel stays on screen, in a corner with no neighbouring display. It is used briefly while a group's shown tab or a workspace is being moved or resized; hidden tabs normally stay stacked behind the shown one. Unlike minimising or hiding, parking has no animation, leaves the app's other windows alone, and the window stays live.

## Website

The landing page lives in `site/` (Next.js, static export): `cd site && pnpm install && pnpm build` writes `site/out/`, which any static host can serve. It reads the latest version from `appcast.xml`, so rebuild it after each release.

## Known limitations

- While a tab or workspace is being dragged or resized, its hidden windows are briefly parked; they still show up in Mission Control, and on leaving it you can see them fly back to the corner.
- Switching tabs sometimes darkens the window shadow for a frame or two: the app applies the two window moves in different frames.
- Finder won't go fully off screen, so a parked Finder window leaves about 20 px visible.
- Minimising the shown tab, or a window inside a workspace, takes it out of its group/workspace.
- Groups and workspaces are saved on an orderly quit and restored on the next launch. A crash or Force Quit loses the saved state; the windows themselves stay where they are.
- A workspace wraps real windows from different apps, so its panes keep their own title bars, shadows and rounded corners; it is not a single seamless window.
- A pane's edge drag lets the app resize first. On release an outer edge resizes the workspace and an inner edge updates the splitter ratio; the panes re-layout. A top edge under the workspace header snaps back. Plain clicks work normally, and the app's own resize cursor may still appear on hover.
- Full-screen windows, sheets and windows with native tabs inside a workspace are best-effort.
- Dragging a window out of an edge tile can't drop it onto another group (its size changes during that drag).

## License

[MIT](LICENSE). Not covered: `site/public/macbook-pro.webp` is Apple's MacBook Pro product bezel, used under the Apple Design Resources license; it may not be redistributed on its own.
