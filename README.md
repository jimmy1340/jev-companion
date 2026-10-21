# Jev Companion · Jev 伴聊

A native, read-only WeChat conversation companion for macOS and Windows. Jev supplies typed judgments; an optional OpenAI-compatible reply model supplies drafts. You review and send every message yourself.

[简体中文](README.zh-CN.md) · [macOS setup](macos/README.md) · [Windows setup](windows/README.md) · [Privacy](docs/PRIVACY.md) · [Validation](docs/VALIDATION.md)

## What it does

- Reads text exposed by the current WeChat window, accepts pasted text, or loads a synthetic demo.
- Places analysis cards below the corresponding messages in its own window. Each card uses only the conversation prefix available at that message.
- Uses TypeSafe Jev Noul, Choice and Score primitives for communication needs, next actions and conversation tension.
- Generates two optional reply drafts through a local OpenAI-compatible `/v1` endpoint such as 9Router.
- Offers opt-in local SQLite memory on macOS, isolated by conversation. Windows currently keeps conversations in memory only.

The assistant does not send messages, modify WeChat, decrypt databases, or inject code. Probabilities are model estimates about text, not measurements of another person's thoughts.

## Project status

This is the first public source edition of a personal prototype. The repository edition is **0.1.0**; the macOS app is **0.3.1** and the Windows preview is **0.4.1**. These platform versions describe their respective implementations, not release maturity.

macOS has historical manual verification of WeChat text reading and synthetic model requests. Windows builds and core tests are available; its new window OCR path still needs testing on a real Windows machine. See the dated [validation record](docs/VALIDATION.md). Automated tests never require WeChat, production credentials, or live inference.

## Build from source

### macOS 13 or later

Install Apple Command Line Tools and Python 3.9 or later. No Codex installation is required.

```sh
git clone https://github.com/jimmy1340/jev-companion.git
cd jev-companion
bash macos/test.sh
bash macos/build.sh
```

The app is created at `dist/Jev伴聊.app` with a local ad-hoc signature. Configure your own TypeSafe key using the [macOS instructions](macos/README.md). Reply generation is optional. Accessibility permission is only needed for reading WeChat; pasted text and the demo work without it.

### Windows 10 2004 or later and Windows 11 x64

Install .NET SDK 10 to build. The published app includes its runtime.

```powershell
dotnet run --project windows/Tests/Jev.Tests.csproj -c Release
dotnet publish windows/App/Jev.Windows.csproj -c Release -r win-x64 --self-contained true -o dist/windows
Copy-Item dist/windows/JevCompanion.exe dist/windows/JevCompanion-Setup-0.4.1-win-x64.exe
```

Provide your own TypeSafe and/or compatible model credentials in Connection Settings. Windows protects saved credentials with DPAPI. See [Windows usage and limitations](windows/README.md).

## Architecture

```text
Current WeChat window / pasted text / synthetic demo
    -> native UI and a fixed conversation snapshot
    -> user confirmation for cloud processing
    -> Jev typed judgments + optional reply model
    -> analysis cards and copyable drafts
```

macOS uses SwiftUI, Accessibility, Python standard library and SQLite. Windows uses WPF, UI Automation and local OCR. macOS reply endpoints are restricted to loopback; Windows supports authenticated HTTPS endpoints as well. Model services may process text in the cloud even when accessed through a local router.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for tests and synthetic bug reports. Compatibility reports for newer WeChat versions, Windows OCR testing, setup improvements and translations are welcome. Planned work is in [ROADMAP.md](docs/ROADMAP.md).

## License and affiliation

Original source is available under the [MIT License](LICENSE). .NET/WPF notices remain in [windows/Notices](windows/Notices). Apple, Microsoft, Tencent, TypeSafe and model services have their own terms and licenses. This project is independent and is not an official WeChat, TypeSafe or OpenAI product.
