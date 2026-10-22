# Changelog

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
