# Privacy and data handling

## What enters the application

The user selects the current WeChat conversation, pastes text, or loads fictional demo messages. macOS reads text exposed by Accessibility. Windows tries UI Automation and can use local OCR of the selected visible message region. Neither client decrypts the WeChat database or guarantees complete history.

Windows OCR processes the chosen region locally. Screenshots are not uploaded to the model or persisted by the OCR path. Check recognized text and sender labels before analysis.

## What leaves the device

Analyzing real messages requires confirmation. TypeSafe receives the selected text, conversation title, prior context available at that message, and any enabled same-conversation retrieval candidates. An optional reply model receives the relevant text and analysis context. A local router can forward this information to a cloud provider. That provider has its own terms and retention policies; this project cannot guarantee provider-side retention or deletion.

Each historical card uses a prefix of the conversation. macOS disables memory retrieval for older message cards so later saved messages cannot flow backward into their analysis. A conversation or connection change invalidates the prior analysis scope.

## What stays on the device

macOS history is off by default. When enabled it stores original text, source and conversation identity in SQLite under `~/Library/Application Support/JevWeChatAssistant/`. Predictions and drafts are not saved as historical facts. The history is not encrypted by the application. On save, and again on read, a real history directory is set to mode 0700 and the database file to mode 0600. The short-lived SQLite journal is created owner-only as well. The tool refuses to open the database, or its `-journal`, `-wal`, or `-shm` file, when that path is a symlink, a hard link, or not a regular file. A symlinked data directory is left unchanged so chmod cannot follow the link onto an unrelated folder. Use appropriate OS account and disk protection for your environment.

Windows keeps chat and analysis in memory and saves only connection settings; sensitive connection values use DPAPI for the current Windows user. macOS TypeSafe credentials come from the process environment or a dedicated Keychain entry. Optional macOS router credentials come from a dedicated Keychain entry.

## User control

Reading is separate from analyzing. Saving is separate from cloud consent. Forgetting a conversation removes this tool's saved original messages, not WeChat records or provider-side copies. Drafts are copied for manual review and sending. Uncertain speaker identity and OCR mistakes must be corrected by the user.
