# Contributing

This is an early personal project. Contributions that improve reproducibility, WeChat compatibility, uncertainty handling and privacy are welcome.

## Run relevant checks

```sh
python3 -m unittest discover -s macos/backend/tests -v
# macOS only: reader fixtures, state fixtures and Python tests
bash macos/test.sh
# .NET SDK 10: portable core tests
dotnet run --project windows/Tests/Jev.Tests.csproj -c Release
```

Build the affected native app when changing UI or platform code. Windows OCR and Accessibility compatibility need manual testing in addition to synthetic tests; include the exact OS and WeChat version and distinguish a build result from a manual result.

## Report a bug

Describe the expected result, actual result, OS and WeChat version, input mode, and minimal steps. Use fictional text. Never post contact names, real chats, chat databases, screenshots containing private content, API keys or raw provider responses. For a security issue, read [SECURITY.md](SECURITY.md).

## Submit a change

Keep the change focused. Preserve cloud consent, per-conversation isolation, bounded requests, stale-result rejection, clear model provenance, and the absence of automated sending. Add regression coverage when behavior changes. Tests must not require a personal account or production service. Run CI with read-only repository permissions and no inference secrets.

Describe the problem and validation in the pull request. Contributions are provided under the repository's MIT License; retain applicable third-party notices.
