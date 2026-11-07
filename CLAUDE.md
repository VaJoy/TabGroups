# TabGroups — handoff notes

Goal: re-implement TrellisWM's "Tab groups" feature (https://trelliswm.app) as a native
macOS background app (no menu-bar item; Dock icon optional) in Swift: drop a window on the middle of another (from any app) and
pause → they stack under one strip of tabs; click a tab to switch; drag a tab out to tear
it off. Plus a tiled workspace mode: Shift-drop up to four cross-app windows into one
frame (binary split tree), group that frame as a tab, rename tabs inline, and fill the
current display by double-clicking the workspace header. Code comments in English; the
user prefers to talk in Chinese.

## Status

- Builds cleanly (Swift 6.4 toolchain, no warnings). Basic loop verified with synthetic
  mouse events: group (incl. cross-app, 3 tabs) → switch → tear off → quit restores.
- Workspaces/containers: Shift-drag a title bar onto another window or workspace to create
  or insert (max 4, binary split tree; portrait screens split top/bottom first). The shell
  is an `NSPanel`; child windows are AX-positioned. Drag the shell's left/bottom/right edge
  or a splitter to resize all panes; a pane's edge drag lets the app resize itself and
  commits on mouse-up (an outer edge grows/shrinks the workspace, an inner edge updates
  the splitter ratio); a top edge under the workspace header, or a plain move, snaps back.
  Double-click the shell header to fill the visible frame. A workspace
  can be a tab in a group (its shell is the tab window), and a workspace header can be
  dropped onto another window, workspace pane, or group strip to group it. Tab names can
  be renamed inline; custom names are persisted. Groups and workspaces are saved on an
  orderly quit and restored on the next launch.
- Recent workspace/rename/zoom/edge-guard changes build in debug and release; the older
  synthetic-event loop was tested, but the new GUI paths have not all been re-tested.
- Workspace caveats: real child windows keep their own title bars/shadows; children don't
  reattach after a live app update/relaunch; full-screen/sheets/native-tab windows are
  best-effort; pane edge drags commit on mouse-up; the child app's resize cursor may
  still show.
- Hidden tabs are **stacked** right behind the shown one (same frame), not parked off
  screen: parked full-size windows made Mission Control shrink every thumbnail (it lays them
  out where they are), and swapping two windows' positions flickered their shadows. Parking
  small fixed Mission Control but made hidden tabs near-invisible there. The Dock no longer
  posts `AXExposeShowAllWindows` (macOS 27), and Mission Control fixes its layout when it
  opens, so unparking "while it's open" doesn't work.
- Known: stacked windows show through translucent ones (glass sidebars, see-through terminals).
- Swift tools 5.9 (Swift 5 language mode), macOS 14+, no sandbox (Accessibility API
  doesn't work sandboxed). All app classes are `@MainActor`; C callbacks / timers / event
  monitors hop in with `MainActor.assumeIsolated`.
- Run: `swift run` (the Accessibility grant goes to Terminal) or `./make-app.sh &&
  open build/TabGroups.app` (ad-hoc signed; the grant may reset after each rebuild).

## Architecture

| File | Role |
|---|---|
| `AX.swift` | AX helpers, private `_AXUIElementGetWindow` (via `@_silgen_name`), `Focus` (SkyLight `_SLPSSetFrontProcessWithOptions` + a synthetic key-window event via `dlsym`, as yabai/AltTab do: AX alone raises a tab but its app keeps keyboard focus in the previously key window), `Coords` (AX top-left ↔ AppKit bottom-left) |
| `WindowTracker.swift` | One `AXObserver` per regular app; `[CGWindowID: Win]`; `topWindow(at:excluding:)` via `CGWindowListCopyWindowInfo` z-order |
| `DragController.swift` | `NSEvent` global monitors; detects a title-bar drag via WindowServer bounds (`Win.serverFrame`; AX position lags mid-drag) and moves the strip with that frame (`GroupManager.dragMoved`); middle zone = target inset 25%; dwell 0.35 s with the pointer nearly still (4 px) → `DropHighlight`; moving on after that takes the highlight back, so only a release while still groups; mouse-up → `GroupManager.join`. Grouping only while the drag key (`DragKey`, ⌘ by default) is held. Drag key + press anywhere in a window: an active `CGEventTap` swallows the press and moves the window by AX (the pointer and the key state come from the tapped events: `NSEvent.mouseLocation` freezes while a drag is swallowed, and the polled modifier state glitches across displays); a press that doesn't move > 3 px is replayed as a click. The same tap takes switch key + 1…8 / + 9 (last) when the focused window (`GroupManager.focused`) is in a group: switches tab, swallows the key (even out of range). `SwitchKey` (`UserDefaults` `switchKey`: ⌥ default, ⌃ ⌘ ⌃⌥): not ⌘ by default because apps' own ⌘1…9 can't be detected (T3 Code/Electron handle them in the page, not the menu bar). With ⌘, a window with its own tab bar of 2+ tabs (`AX.hasOwnTabs`: an `AXTabGroup` child, i.e. native window tabs like Ghostty/Safari/Finder) keeps them and the strip drops its hints. Shift-drop creates/inserts workspaces; child edge drags are left to the app, and the Container commits outer edges to the workspace frame / inner edges to the splitter ratio on mouse-up; the tap skips press-anywhere moves on container children. |
| `GroupManager.swift` | `TabGroup` model (frame includes the 34 px strip). All tabs share `windowFrame`; select = raise the shown tab (nothing moves); `layout` → `stack` puts the hidden ones back in the frame. While the shown tab is dragged/resized the hidden ones are **parked** (bottom-right corner, 1 px visible) and re-stacked when it settles. On app activation the tab that ended up on top becomes the shown one. Ignores our own AX writes for 0.5 s. Ungroups everything on quit, after `save()` (UserDefaults `savedGroups`: window IDs + bundle ID + title + frame); `restore()` on start matches by window ID (the other apps kept running), else by bundle ID + title if unambiguous. A tab whose app goes away (an update relaunching it, a crash, ⌘Q) is remembered for 2 min (`Lost`: bundle ID, pid, title, the other tabs); a new window of that app from another process takes its place (`bringBack`, title match first), so a restarted app rejoins its group. It also hosts the workspace integration: container shells are group tabs; selecting a container activates/deactivates it; custom tab names; header double-click zoom; hidden children collapse when their window is hidden on close; groups and containers are both saved/restored. |
| `ContainerLayout.swift` | Binary split tree (max 4 leaves): insert at target or largest leaf, default side, minimum pane sizes, splitter geometry, `Codable` |
| `Container.swift` | Workspace model: child `Win`s, AX layout, splitter panels, pane-edge commits (outer frame / inner splitter), activation/z-order, custom title, pre-group frames, release of child windows |
| `ContainerWindow.swift` | Workspace shell (`NSPanel`): header, left/right/bottom resize panels, splitter overlays, header drag and double-click zoom |
| `ContainerManager.swift` | Create/insert/remove workspaces, child-window map, hidden-child cleanup hook, persistence (`savedContainers`) |
| `TabStrip.swift` | `TabStripPanel`: borderless non-activating `NSPanel`, `.normal` level, `order(.above, relativeTo: activeWindowID)`. `TabStripView`: draw, hover ✕, drag to reorder, drag beyond 24 px → torn (`TabChip` follows the pointer). Ghostty-style `⌥N` (switch key) hint on the right of each tab, hover ✕ on the left; double-click a title to edit it in `TabRenameEditor` (Enter commits, Escape cancels, empty resets). |
| `Settings.swift` | `SettingsWindow`: the app's only window (Liquid Glass via `NSGlassEffectView` on macOS 26+), shown on open/reopen but not on a login launch; *Drag key* (`UserDefaults` `dragKey`: ⌘ ⌥ ⌃ fn), *Switch tabs* key (`switchKey`), *Launch at login*, *Show in Dock* (`UserDefaults` `showInDock` → activation policy), *Check for / Install updates automatically* (Sparkle's `automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates`, on by default from Info.plist), *Quit* |
| `Support/AppIcon.icon` | Icon Composer file (open it in Icon Composer to edit): three SVG layers on a 1024 canvas (back window, dark tab strip, front window) with Liquid Glass. `make-app.sh` compiles it with `actool` (needs Xcode) into `Assets.car` + a fallback `AppIcon.icns` |
| `Updates.swift` | Sparkle (`SPUStandardUpdaterController`, app bundle only): checks `SUFeedURL` = `appcast.xml` on main (raw.githubusercontent) every 6 h (`SUScheduledCheckInterval`), downloads updates by itself (`SUAutomaticallyUpdate`; installed on quit). A found update (scheduled check, or downloaded and waiting for quit) shows a badged Dock icon (`Updates.pending`, kept through `applyDockPolicy`); clicking it calls `checkForUpdates`, which shows the waiting update. Updates are verified with `SUPublicEDKey`; the private EdDSA key is in Infisical (org RiPPLEX, project TabGroups `tab-groups-igw2`, env prod, `SPARKLE_ED_PRIVATE_KEY`; the repo is linked via `.infisical.yaml`), with a copy in the login keychain where Sparkle's `generate_keys` made it. `release.sh` reads it from Infisical (`infisical login` first). Publish with `SIGN_IDENTITY=… ./release.sh <version>` (bumps the version, builds, zips, `generate_appcast`, GitHub release, pushes the appcast). `make-app.sh` embeds Sparkle.framework in Contents/Frameworks and signs its helpers inside out |
| `App.swift` | `@main`, `LoginItem` (launch at login via `SMAppService.mainApp`, app bundle only), minimal app menu (⌘, ⌘W ⌘Q), AX permission prompt + polling, SIGINT/SIGTERM → terminate (so windows get restored) |
| `site/` | Landing page (Next.js, static export to `site/out`; `cd site && pnpm install && pnpm build`). `/` English, `/zh/` Chinese, two root layouts under route groups; all copy in `lib/content.ts`. Version, size and download URL come from `appcast.xml` at build time (`lib/release.ts`), so rebuild after a release. The hero is a working pretend desktop (`components/Desktop.tsx`) using the app's own numbers (25% inset, 4 px / 0.35 s dwell, 24 px tear-off). The story's MacBook is Apple's product bezel (`public/macbook-pro.webp`, Apple Design Resources license: depicting a macOS-only app is allowed, follow Apple's marketing guidelines, don't redistribute it on its own). Product facts: `PRODUCT.md`; visual system: `DESIGN.md` |

## Next steps (suggested order)

1. ~~Compile, run, check the basic loop~~: done.
2. ~~Strip z-order~~: done — re-ordered (with delays) on focus change and on app activation.
3. Group-level controls on the strip (close / minimise the whole group), as TrellisWM has.
4. Skip or handle windows with native tabs (`AXTabGroup` child), full-screen windows, sheets; inside workspaces these are best-effort.
5. ~~Persist groups and restore them on launch~~: done (not across a crash: saved on quit only; containers too; after a reboot apps open their windows after we start, so most aren't found; container children are not reattached when an app relaunches while running).
6. Optional: ScreenCaptureKit thumbnail of the tab under the pointer while it's being dragged.
7. Workspace follow-ups: reattach container children when an app updates/relaunches (Lost/returned currently only for group tabs); add a cursor override for child edges (the app still shows its resize cursor); consider editing the workspace header title (only tab titles are renamed now); verify header/gutter drops when grouping a workspace onto another workspace (currently a pane-center drop).

Never leave windows parked or stacked: every exit path must call `groups.save()`, `groups.ungroupAll()` and `groups.containers.releaseAll()`.
