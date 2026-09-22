# Release validation — 0.24.0

Validated on an Apple silicon Mac with Swift 6.4 and the macOS 27 SDK.
The app deployment target is macOS 14; older supported macOS versions have
not been physically retested for this public release.

- Swift tests: 174 total, 170 passed, 4 opt-in real-server tests skipped.
- Remote PTY helper: 6 local lifecycle and transport tests passed.
- File runtime: 6 file-operation tests passed.
- A fresh release build from the public source completed.
- Optional viewer fallback, user-installed assets, token-scoped access, and
  rejection of symlinks outside the viewer directory are covered by tests.
- Source distribution is checked for personal host/account fixtures, private
  keys, tokens, app data, generated NVIDIA assets, and build caches.

The Python PTY tests require local Unix-socket/PTY access. A restricted agent
sandbox blocked their first run; the normal local environment passed all six.
No production server settings were changed for publication.

The tests do not constitute notarization, penetration testing, or validation
on every remote operating system and simulator version. The initial downloadable
app is ad-hoc signed and must be explicitly allowed by the user at first launch.
