# Security Policy

FanCurve installs a root launch daemon and asks for Accessibility access, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through [GitHub Security Advisories](../../security/advisories/new) and include steps to reproduce. You'll get a reply within a few days.

## Scope

In scope:

- **The fan service:** `fancurved` and its config and status files in `/Library/Application Support/FanCurve/`.
- **The update mechanism:** GitHub Releases, the local update server, checksum verification, and the administrator-privilege install step.
- **Input handling:** the event taps used for snippets, brightness keys and keyboard cleaning mode.

## Design notes

- **The fan service only reads its JSON config.** Its sole privileged action is writing fan mode and target keys to the SMC.
- **Updates are checksum-verified before installing.** They install only after an explicit administrator-password prompt.
- **Snippet expansion never reads secure input**, such as password fields.
- **GitHub tokens are stored in the login Keychain**, never in files.
