# Nopilote

A privacy-conscious macOS menu bar assistant for the currently selected Apple Note.

## Requirements

- macOS 15 or newer
- Xcode 16 or newer
- An API key for OpenAI, Anthropic, Gemini, DeepSeek, Qwen, or Zhipu

## Build and run

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/Nopilote.app
```

On first use, macOS asks whether Nopilote may automate Apple Notes. Allow this under **System Settings > Privacy & Security > Automation**. Add a provider, model, and API key in the app's Settings window. Each provider keeps its own API key and model selection; switching providers does not clear the others. API keys stay in Nopilote's private local settings. Image attachments in the selected note are sent to vision-capable models (OpenAI, Anthropic, Gemini, and models explicitly named with `VL`, `Vision`, or `4V`); text-only models receive text only.

## Current MVP

- Reads the selected, unlocked note through Apple Notes' public AppleScript interface.
- Left-click the menu bar icon or use `Option-Space` to open the compact panel. On first launch it opens on the normal desktop even if another app is currently full screen. It is draggable and normally stays below whichever app you switch to. Right-click the icon for `Open Nopilote`, refresh, settings, and quit. Use the pin button only when you explicitly want it kept above other windows and Spaces.
- Answers questions, summarizes, outlines, rewrites, condenses, expands, and polishes notes.
- Generates Apple Notes-friendly rich structure: heading hierarchy, styled callouts, code blocks, dividers, checklists, bullet/numbered lists, and compact tables with headers. All edits are previewed before writing.
- Keeps notes and chat history in memory only. The session is cleared on screen lock, app exit, manual ending, or 30 minutes of inactivity.
- Shows a side-by-side preview before every write.
- Rechecks lock state and modification time immediately before writing.
- Creates a separate organized note when the original contains tables, images, attachments, native checklists, or other complex structures.
- Uses an ephemeral network session without URL cache or cookie storage.

The MVP intentionally targets the current note on macOS. Folder-wide retrieval, full-library temporary search, batch organization, and iPhone share/shortcut entry points are later phases. Apple does not expose an iOS API for traversing the complete Notes library.

## Privacy boundary

Locked notes are rejected before their body or plaintext properties are accessed. The app does not inspect the Notes database or private CloudKit storage, and it does not use Accessibility UI automation. Persistent storage is limited to non-content preferences and Keychain credentials.

The signed app enables App Sandbox with outbound network access for model APIs and an Apple Events exception for `com.apple.Notes` only. It has no file, Accessibility, camera, microphone, contacts, calendar, location, or automation permission for other apps.
