# MyBar 1.1 — build 20

Published from the current local source on November 5, 2026.

Build 20 packages the source correction prepared after build 19. Any known
nonzero macOS four-finger horizontal mapping is treated as a system reservation,
including the previously misinterpreted `(three=2, four=2)` combination. The
settings explain the conflict and the feature remains opt-in. The separate
configuration utility is explicit, supports backup/restore and is never invoked
automatically by the release. Real browser tab switching remains unverified.

## Downloads

- `MyBar-1.1-build20-arm64.zip`: Apple silicon app, macOS 14.2+.
- `MyBar-build20-visuals.zip`: banner, feature graphic, social card and screenshots.
- `SHA256SUMS.txt`: SHA-256 checksums for these assets.
- GitHub's source archives: the exact tagged source.

The app is signed ad-hoc, not Developer ID signed or notarized. It is a development
preview, not a Mac App Store build. Optional fan-control hardware compatibility,
private gesture API compatibility and end-to-end audio behavior need testing on
each target configuration. Menu bar hiding on macOS 27 stays disabled.

## Verification

- Release compile with warnings treated as errors.
- 196 tests run: 192 passed, 4 skipped, 0 failures.
- Skipped: opt-in offline audio conversion, two opt-in performance probes, and
  a menu-helper check that expects the debug build directory.
- Packaged app: strict nested signature verification, 12 cached pet frames,
  8 switch packs / 24 recordings, trackpad-helper protocol, broken-pipe isolation
  and non-executable menu-hiding helper.
- ARM64 executable and matching version 1.1 / build 20 inspected.

The installed build 19 was not replaced during publication. Existing app
permissions and system gesture settings were not changed.
