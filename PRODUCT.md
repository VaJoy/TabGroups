# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (the landing page). The product itself is a native macOS app.

## Stack

Landing page: Next.js, following its best practices (user's choice). Static export so it can sit on any static host.

## Users

Ordinary Mac users who keep several windows open at once, often from different apps (a browser, notes, a terminal, a chat app), and lose time hunting for them. They are not assumed to be developers; the page should avoid jargon such as Accessibility API, AXObserver or Swift.

## Product Purpose

TabGroups gives any window from any app browser-style tabs. Hold ⌘, drag one window onto the middle of another and pause a moment: they stack under one strip of tabs. Click a tab to switch, drag it to reorder, drag it out to make it a window again. It can also tile up to four cross-app windows into one workspace: hold Shift and drop a window onto another window or onto a pane of an existing workspace, drag the workspace edges or splitter lines to resize the panes together, double-click its header to fill the display, and group the whole workspace as a tab. Double-click a tab name to rename it. Success: a visitor understands the drop-and-pause gesture in seconds, downloads the app, and grants the one permission it needs.

## Positioning

Tabs across apps, not inside one app: a browser tab, a Notes window and a terminal can share one strip. A workspace goes further, tiling up to four of them in one frame that can itself become a tab. Nothing to learn beyond the drag you already do; it runs in the background with no menu-bar item.

## Operating Context

- Download: GitHub Releases (`https://github.com/passion729/TabGroups/releases/latest`), a zipped `TabGroups.app`.
- First launch asks for Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility); the app starts as soon as it is ticked.
- Opening the app again shows its one settings window (drag key, switch key, launch at login, show in Dock, updates, quit).
- Updates install themselves (Sparkle).

## Capabilities and Constraints

- Group: hold the drag key (⌘ by default; ⌥ ⌃ fn selectable) and drag a window (from any spot in it, not just the title bar) onto the middle of another or onto a group's strip, hold still ~0.35 s, a highlight appears, release. Grouping only happens while the drag key is held.
- Switch: click a tab, or switch key + 1…8 (9 = last); ⌥ by default.
- Reorder by dragging a tab along the strip; tear off by dragging it more than 24 px away; hover ✕ closes that window; right-click for Remove from Group / Ungroup All (that group only).
- Workspaces: hold Shift and drag a window by its title bar onto another window or a pane of an existing workspace to create or insert, up to four panes. Drag the workspace's left/bottom/right edge or a splitter line to resize all panes together; a pane edge lets the app resize first, then on release an outer edge resizes the workspace and an inner edge updates the splitter ratio, and all panes adapt. Double-click the workspace header to fill the display; drag its header to move it. Hold the drag key and drag a workspace header onto another window, another workspace pane or a group's strip to make the whole workspace a tab.
- Rename: double-click a tab title, type, press Return; an empty name restores the default.
- The strip follows the window when it moves, resizes or tiles to a screen edge.
- Groups and workspaces are saved on an orderly quit and restored on the next launch; quitting puts every window back.
- macOS 14 or later, Apple Silicon only (arm64). Not on the Mac App Store (needs Accessibility, which doesn't work sandboxed).
- Known limits: windows behind show through translucent windows. A workspace wraps real windows, so panes keep their own title bars/shadows and are not seamless; children don't reattach after a live app relaunch; a pane edge drag commits on release (outer edge to the workspace, inner edge to the splitter; a top edge snaps back), plain clicks work normally, and the app's own resize cursor may still show; native-tab, full-screen and sheet windows are best-effort. A crash or Force Quit loses saved groups/workspaces.

## Brand Commitments

- Name: TabGroups.
- Free and open source under the MIT license (`LICENSE`); source at https://github.com/passion729/TabGroups.
- Credit: inspired by the Tab groups feature of TrellisWM (https://trelliswm.app).
- State Apple Silicon / macOS 14+ plainly.
- English and Simplified Chinese, switchable.
- Existing assets: app icon (`Support/AppIcon.icon`, three SVG layers), promo image source (`docs/promo.html`). Not binding as a visual direction.

## Evidence on Hand

- Real feature behavior (above), version history in `appcast.xml` (0.1 → 0.6, October 2026).
- No users, testimonials, press, download counts or benchmarks. Do not invent them.

## Product Principles

1. Show the gesture, don't describe it: the drop-and-pause (and Shift-tiling for workspaces) is the whole product.
2. Plain words for ordinary Mac users; technical detail lives on GitHub.
3. Honest about requirements and limits (Apple Silicon, macOS 14+, Accessibility permission).
4. Feels like a native Mac utility: quiet, precise, out of the way.
