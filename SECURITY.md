# Security policy

The initial public source edition is the supported development line. There is no guaranteed response time or commercial support agreement.

## Report a vulnerability

Do not put credentials, real chat messages, screenshots or exploit details exposing private content in a public issue. Contact the maintainer through their GitHub profile to arrange a private reporting channel. If GitHub offers private vulnerability reporting for this repository, use that channel.

Include the affected version, a synthetic reproduction, impact, and a suggested mitigation if available. Never attach a WeChat database or a live API key. Rotate a leaked credential through its provider; opening an issue does not revoke it.

## Intended boundaries

The companion does not send WeChat messages, decrypt its database, inject code, or change system protections. Cloud analysis requires confirmation for real messages; persistent local history is separately opt-in. Desktop users and configured model services can access the text they authorize. Local SQLite history is not application-level encrypted and relies on OS account/disk protections. Review [PRIVACY.md](docs/PRIVACY.md) before use.
