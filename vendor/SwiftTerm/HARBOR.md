# SwiftTerm in Harbor

Upstream: https://github.com/migueldeicaza/SwiftTerm

Base revision: `5d14406844143538cd8f8851d2d8a67c1fe443e5`

This source snapshot includes local changes in:

- `Package.swift`: disable the optional benchmarking dependency for app builds.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift`
- `Sources/SwiftTerm/Mac/MacTerminalView.swift`
- `Sources/SwiftTerm/Terminal.swift`

The terminal changes support Harbor's copy handling, current-directory tracking,
and full-display invalidation. Keep these changes when updating SwiftTerm.
The original [MIT license](LICENSE) applies. Upstream repository history and
generated build products are not vendored.

