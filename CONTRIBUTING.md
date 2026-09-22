# Contributing

Bug reports and focused pull requests are welcome. Check existing issues first.
Include the Harbor/macOS versions, expected behavior, and small reproduction
steps. Use sample hosts such as `gpu.example.org` and remove credentials,
server addresses, file contents, and private terminal output from attachments.

Build and test using the commands in [README.md](README.md). Keep UI text in
English. Prefer native SwiftUI/AppKit interaction, preserve active terminal
sessions, and keep heavy previews bounded in memory. Add a regression test
when changing connection, file operation, or terminal lifecycle behavior.

Use an isolated `HARBOR_DATA_DIR` for manual development. Tests create their own
temporary fixtures. Real-server tests require explicit opt-in; do not put live
credentials or personal server configurations into tests or the repository.

The bundled editor must be rebuilt when changing `Editor/editor.js`. Preserve
third-party notices and the [SwiftTerm patch notes](vendor/SwiftTerm/HARBOR.md).
Never commit `node_modules`, compiled NVIDIA viewer assets, or app data.

Contributions are accepted under the repository's MIT license, with existing
third-party licenses preserved. See [SECURITY.md](SECURITY.md) for vulnerabilities.
