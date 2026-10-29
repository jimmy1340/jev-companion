# Contributing

This is an early personal project. Contributions that improve reproducibility, WeChat compatibility, uncertainty handling and privacy are welcome.

## Run relevant checks

Run these from the repository root. They use fixtures only: no WeChat window, production credential, or live inference.

```sh
# Any machine with Python 3.9 or newer, including Linux
python3 -m unittest discover -s macos/backend/tests -v

# macOS only. Needs Command Line Tools (xcrun, swiftc) and /usr/bin/python3 >= 3.9.
bash macos/test.sh
bash macos/build.sh

# .NET SDK 10. The project below is the portable core, so it can run on Linux or macOS.
dotnet run --project windows/Tests/Jev.Tests.csproj -c Release

# Windows app publish. Cross-compile from macOS is possible; running the window needs Windows.
dotnet publish windows/App/Jev.Windows.csproj -c Release -r win-x64 --self-contained true -o dist/windows
```

`macos/build.sh` refuses to continue when `/usr/bin/python3` is older than 3.9. It does not look up Homebrew or pyenv. `dotnet --list-sdks` should show a `10.0` SDK before the Windows commands. Outputs belong in `dist/` and `macos/.build/`; do not commit them, `settings.json`, or a key.

Build the affected native app when changing UI or platform code. Windows OCR and Accessibility compatibility need manual testing in addition to synthetic tests; include the exact OS and WeChat version and distinguish a build result from a manual result. A Linux result does not cover SwiftUI copy or the WPF window.

## Report a bug

Describe the expected result, actual result, OS and WeChat version, input mode, and minimal steps. Use fictional text. Never post contact names, real chats, chat databases, screenshots containing private content, API keys or raw provider responses. For a security issue, read [SECURITY.md](SECURITY.md).

## Submit a change

Keep the change focused. Preserve cloud consent, per-conversation isolation, bounded requests, stale-result rejection, clear model provenance, and the absence of automated sending. Add regression coverage when behavior changes. Tests must not require a personal account or production service. Run CI with read-only repository permissions and no inference secrets.

Describe the problem and validation in the pull request. Contributions are provided under the repository's MIT License; retain applicable third-party notices.
