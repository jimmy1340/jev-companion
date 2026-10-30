# Validation record

## Source edition prepared on 2026 10 21

The following checks ran against the public source candidate on an Apple Silicon Mac. They used synthetic fixtures and did not read WeChat, send messages, or call live inference services.

| Check | Result |
| --- | --- |
| Python backend and TypeSafe transport | 56 tests passed |
| Swift Accessibility parser fixtures | Passed, including 3.8 and 4.x synthetic structures, speaker ambiguity, identity and read budgets |
| Swift application state fixtures | Passed, including cloud consent, conversation changes, prefix-only analysis, stale results and cancellation |
| macOS native build | Passed; local ad-hoc signature verified |
| Windows portable core | 39 checks passed using .NET SDK 10 on macOS |
| Windows x64 WPF publish | Cross-compiled successfully with its runtime |

The bundled Python transport was tested with synthetic HTTP responses, including credential precedence, refusal of redirects, HTTP errors, response limits and sanitized errors. This packaging pass did not make a fresh live TypeSafe request. Builds do not prove current WeChat compatibility or installation behavior on another machine.

## Prototype observations from 2026 09 21

The earlier macOS 0.3 prototype had manual verification of reading text from a real WeChat 3.8.6 window. Its demo completed Jev analysis and reply generation using fictional messages. Real chat text was not uploaded in that validation.

Windows 0.4.0 had user evidence that the UI opened but chat-control detection failed. Windows 0.4.1 added raw UIA structure handling and a selected-window OCR fallback. This new path was cross-compiled and tested in the portable core; installation, actual OCR, occlusion handling and region reuse still require real Windows verification.

## Maintenance pass on 2026-10-30

History permission checks were added in source. On Linux, `python3 -m unittest discover -s macos/backend/tests -v` passed (73). The new cases cover a loose umask, a pre-existing mode 0755 directory, symlink, hard-link, and fifo database paths, sidecar links, and a symlinked data directory whose target mode must stay put. They use temporary files only. Swift fixtures, the Windows test project, `macos/build.sh`, and the WPF window were not executed; those sources did not change. No WeChat window or live model was used.

## Maintenance pass on 2026-10-29

Credential guidance and the install notes were updated in source. On Linux, the Python backend tests passed (67) and the Windows portable core passed with .NET SDK 10.0.403 (64 checks). Neither run read WeChat or called live inference. Swift fixtures, `macos/build.sh`, and the WPF window were not executed here; those still need macOS and Windows. The manual checks below are unchanged.

## Remaining manual checks

- Configure the standalone macOS TypeSafe client on a clean machine and analyze only fictional text first.
- Check current WeChat versions and permissions on each target OS.
- Verify Windows installation/update, UIA capture, OCR language availability, sender labels, window occlusion, DPI and region invalidation.
- Exercise follow mode with explicit user consent; do not infer sustained live behavior from synthetic state tests.

There is no claim of universal WeChat compatibility, model accuracy, download adoption, or public CI completion in these local results.
