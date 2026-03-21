# Nova Inject

Enhancements for [Nova](https://nova.app) by Panic, injected via a dylib.

## Features

### 1. Lock Split (Cmd+Shift+L)

Nova has a fully implemented but hidden **Lock Split** feature. When you lock a split, files opened from the sidebar skip that split and open in an unlocked one instead. This lets you keep a terminal pinned without it getting replaced.

The dylib unhides the menu item at **View > Splits > Lock Split** and swizzles `validateMenuItem:` on `NovaWorkspaceTabViewController` to prevent Nova from re-hiding it.

### 2. Send File Ref to Terminal (Cmd+L)

Sends the current editor file path and line number to the active terminal. Useful for referencing code when chatting with Claude Code or similar tools.

**Output format:**
- Cursor on line 42: `@src/tools/external/hightouch.py:42`
- Selection spanning lines 6-9: `@.gitmodules:6-9`

Paths are relative to the workspace root.

## How It Works

A single Objective-C dylib (`nova_inject.dylib`) loaded into Nova at launch. It:

1. **Lock Split**: Walks the menu tree to find the hidden `toggleLocked:` menu item under View > Splits and unhides it. Swizzles `validateMenuItem:` to keep it visible.

2. **Cmd+L**: Removes the Cmd+L binding from Nova's built-in "Select Line" menu item, then adds a "Send File Ref to Terminal" item to the Editor menu. When triggered, it:
   - Reads the cursor position via `selectedRange` on `NovaCodeTextView`
   - Gets the file content via `textStorage.string` to count newlines and determine line numbers
   - Walks the responder chain to find `document.fileURL` (from `NovaCodeDocumentViewController`) for the file path
   - Walks further to find `workspace.workspaceURL` (from `NovaWorkspace`) to make the path relative
   - Finds the first `PMTTerminalView` in the window via BFS of the view hierarchy (this consistently targets the sidebar terminal, not the bottom panel)
   - Types the reference into the terminal via `insertText:`
   - Also copies to clipboard as fallback

No bytes are patched in the Nova binary. The dylib is copied into the app bundle at `Contents/Frameworks/nova_inject.dylib` and loaded via `LSEnvironment` in `Info.plist`. The app is re-signed ad-hoc after patching.

## Files

- `nova_inject.m` — Objective-C source
- `nova_inject.dylib` — Compiled dylib (arm64)
- `install.sh` — Patches Nova.app to load the dylib on every launch

## Build

```sh
clang -arch arm64 -dynamiclib -framework Cocoa -o nova_inject.dylib nova_inject.m
```

## Install

```sh
./install.sh
```

This copies the dylib into `Nova.app/Contents/Frameworks/`, adds `LSEnvironment` to `Info.plist`, re-signs the app, and rebuilds the launch services database. Re-run after Nova updates.

## Compatibility

- Tested with Nova (ad-hoc signed, arm64)
- Requires macOS on Apple Silicon
- Won't work if Nova enables hardened runtime with library validation in a future update
