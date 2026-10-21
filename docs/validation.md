# Validation of the 0.36.0 source update

Prepared on 2026-10-21 from the local Harbor 0.36.0 (build 78) source.
This updates source code and documentation; it does not publish a new binary release.

- Swift application and test targets compiled successfully with Apple Swift 6.4.
- Core Swift run: 77 tests, 69 passed, 1 opt-in test skipped, 7 local gateway
  fixture failures. All seven require binding a local socket in this restricted
  execution environment; the fixture reports “Address already in use”.
- Workspace runtime: 9 tests, 8 passed and 1 skipped.
- Editor JavaScript checks: catalog (3), occlusion (5), settings (9) and terminal
  (6) tests passed. Two pinned-runtime fixtures skipped without an explicitly
  provided runtime. Navigation tests could not start their local HTTP bridge.
- Full native UI and Python PTY/workbench runs were attempted. This environment
  prohibits local socket listeners and some GUI services, so these runs do not
  establish a full regression pass. The native run was interrupted when a GUI
  service could not start.
- Public source excludes local application state, dependency installs, backups,
  sampling logs and the separately licensed, optionally installed NVIDIA viewer.
  Managed proxy destinations and a server-password test fixture use examples.

The GitHub macOS workflows run the full Swift, PTY, file-runtime and editor
checks, then build and verify the application archive. Their result must be
checked separately; a successful local compile is not a full test pass.
