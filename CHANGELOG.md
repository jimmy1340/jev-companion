# Changelog

## Unreleased

- First-run credential guidance now distinguishes a missing credential, an empty variable, a malformed key, and a rejected key. Keys are still not bundled, echoed, or taken from another tool's account.
- Install docs name `/usr/bin/python3` from the Apple Command Line Tools, the .NET SDK 10 requirement, and which tests run without WeChat.
- `macos/build.sh` stops early when `/usr/bin/python3` is older than 3.9.

## 0.2.1

- **Refined Apple-Style Visual Hierarchy**:
  - **macOS**: Added subtle gradient depth and border contrast to iMessage-style chat bubbles. Added dynamic status chips (active monitoring capsule and demo mode tag) in the header.
  - **Jev Analysis Cards**: Introduced SF Symbol iconography for each analysis section (诉求、分歧线索、核对记录、建议动作), and a color-coded intuitive gauge badge and progress bar for tension levels (green for calm, orange for mild divergence, red for high tension).
  - **Empty State Experience**: Redesigned the empty conversation placeholder with multi-layer ambient depth, clear typographic hierarchy, and feature guarantee badges (只读不注入、逐条上下文、人工确认发送).
  - **Windows WPF**: Upgraded analysis cards with section badge headers, color-coded tension meters, distinct suggestion cards, and unified Apple-blue primary actions.
- **Platform Parity & Fixes**:
  - Ensured Windows WPF source files (`MainWindow.cs`, `Program.cs`, `RegionSelector.cs`, `ScreenshotReader.cs`) are fully in sync with the repository.

## 0.2.0

- **Apple-style UI Refresh**: Redesigned macOS SwiftUI and Windows WPF views with iMessage-inspired blue and light gray bubbles, refined hairline analysis cards with probability progress bars, and unified blue primary action buttons.
- **Keyboard Shortcuts**: Added platform shortcuts for core actions (macOS: `⌘R` refresh, `⌘Enter` analyze, `Esc` stop; Windows: `Ctrl+R` refresh, `Ctrl+Enter` analyze, `Esc` stop, `Ctrl+P` pin).
- **WeChat Windows OCR Resilience**: Enhanced green bubble detection in `ScreenshotReader.cs` to accurately recognize outgoing messages in both WeChat light and dark modes.
- **Automated CI/CD Release Pipeline**: Added `.github/workflows/release.yml` to automatically build macOS `.app` (arm64 zip) and Windows single-file standalone installer (`JevCompanion-Setup-win-x64.exe`) upon tag push.

## 0.1.0 source edition

Initial public packaging of the macOS 0.3 prototype and Windows 0.4.1 preview.

- Organize native clients into `macos/` and `windows/`.
- Add the MIT License, bilingual overview, privacy notes, contribution guidance and CI.
- macOS 0.3.1: bundle the TypeSafe transport, remove the private Codex dependency, use dedicated credential names, discover reply models, and make router authentication optional.
- Keep build outputs and personal data outside version control.
- Preserve Windows 0.4.1 behavior and third-party runtime notices. Window OCR still requires real-device verification.
