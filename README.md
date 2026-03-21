# Nova Extension Claude

Enhancements for [Nova](https://nova.app) by Panic, injected via a dylib. Designed for use with Claude Code.

## Features

### 1. Lock Split

Nova has a fully implemented but hidden **Lock Split** feature. When you lock a split, files opened from the sidebar skip that split and open in an unlocked one instead. This lets you keep a terminal pinned without it getting replaced.

The dylib unhides the menu item at **View > Splits > Lock Split**. Lock and unlock via the menu.

### 2. Send File Ref to Terminal (Cmd+L)

Sends the current file reference to the active terminal. Works from:
- **Editor**: sends `@file:line ` or `@file:start-end ` for selections
- **Sidebar file**: sends `@file `
- **Sidebar folder**: sends `@folder `
- **Multiple selection**: sends space-separated refs

Paths are relative to the workspace root. A trailing space is appended so you can continue typing.

**Output format:**
- Cursor on line 42: `@src/tools/utils.py:42 `
- Selection spanning lines 6-9: `@src/tools/utils.py:6-9 `

## How It Works

A single Objective-C dylib loaded into Nova at launch. It:

1. **Lock Split**: Unhides the hidden `toggleLocked:` menu item under View > Splits. Nova's own implementation handles the rest.

2. **Cmd+L**: Removes the Cmd+L binding from Nova's built-in Select Line, then an `NSEvent` monitor catches the shortcut. When triggered:
   - If the first responder is an outline view (sidebar), gets file/folder paths from `PCNode.path` on selected items
   - If the first responder is `NovaCodeTextView` (editor), reads cursor/selection via `selectedRange` and counts newlines in `textStorage.string`
   - Walks the responder chain for `document.fileURL` and `workspace.workspaceURL` to build a relative path
   - Finds `PMTTerminalView` via BFS and types the reference via `insertText:`

No bytes are patched in the Nova binary. The dylib is copied into `Nova.app/Contents/Frameworks/` and loaded via `LSEnvironment` in `Info.plist`. The app is re-signed ad-hoc after patching.

## Files

- `nova_extension_claude.m` — Objective-C source
- `nova_extension_claude.dylib` — Compiled dylib (arm64)
- `install.sh` — Patches Nova.app to load the dylib on every launch

## Build

```sh
clang -arch arm64 -dynamiclib -framework Cocoa -o nova_extension_claude.dylib nova_extension_claude.m
```

## Install

```sh
./install.sh
```

Re-run after Nova updates.

## Limitations

- **Custom keyboard shortcuts don't work.** Nova strips key equivalents from dynamically added menu items, and `NSEvent` local monitors only receive key events that aren't already consumed by the menu system. Cmd+L works only because we first remove it from Nova's built-in Select Line binding, freeing the event for our monitor to catch. Shortcuts like Cmd+Shift+K or Cmd+Shift+L that have no existing menu binding to hijack are silently consumed by Nova's internal key handling before our monitor sees them.
- **Shortcuts are not configurable via Nova's Key Bindings settings.** Nova's settings UI reads from its own internal binding registry. Our shortcut is injected at runtime, bypassing that system entirely.
- **Unlock Split only works via menu.** Lock Split is enabled by unhiding the menu item, and Nova handles the keyboard shortcut natively. However, unlocking via the keyboard shortcut doesn't work — Nova's `toggleLocked:` appears to check the call context and only unlocks when invoked from a direct menu click. Use View > Splits > Unlock Split.
- **Cmd+L always targets the first terminal found via BFS.** This consistently hits the sidebar terminal, not the bottom panel. If your layout differs, the target terminal may not be the one you expect.
- **Nova updates will overwrite the patch.** The dylib and `Info.plist` changes live inside `Nova.app`. Any Nova update replaces the app bundle, requiring `./install.sh` to be re-run.

## Compatibility

- Tested with Nova (ad-hoc signed, arm64)
- Requires macOS on Apple Silicon
- Won't work if Nova enables hardened runtime with library validation in a future update
