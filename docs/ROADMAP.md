# Roadmap

## First maintenance priorities

- Verify the Windows 0.4.1 UI Automation and window OCR paths on real machines, including occlusion, region reuse, DPI and WeChat version changes.
- Gather synthetic compatibility fixtures for newer macOS WeChat versions.
- Improve first-run credential setup and error guidance without bundling keys or changing other tools' accounts. Source now separates a missing credential, an empty variable, a malformed key, and HTTP 401, and says where to put a key for this computer. A clean machine should still confirm the macOS Keychain prompt and the Windows settings dialog.
- Document installation and build reproducibility across clean machines. README, the platform READMEs, and CONTRIBUTING now name the toolchains and which checks run without WeChat. A clean macOS and Windows install remains the confirmation that those steps match a fresh machine.

## Later candidates

- English UI and more localization.
- More stable user-confirmed conversation identity for memory isolation.
- Optional encryption for local history and a clear migration path.
- Maintainer tooling for issue triage, pull request review and synthetic evaluation. Any future model-backed maintenance automation should use its own consent, budget and credential controls.

These are planned directions, not shipped features or promised release dates. Automated sending and WeChat process injection are outside the current application scope.
