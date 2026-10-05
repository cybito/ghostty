---
name: ghostty-release-install
description: "When modifying Ghostty, build the macOS ReleaseLocal app, install it, clean stale LaunchServices registrations, and verify the installed bundle."
---

# Ghostty Release Install

For every Ghostty bug fix or source change that should be delivered locally:

1. Build the macOS app with the repository's ReleaseLocal configuration: `nu macos/build.nu --configuration ReleaseLocal`.
2. Use `macos/build/ReleaseLocal/Ghostty.app` as the delivery artifact. Do not use `zig-out/Ghostty.app`; the generic Zig build can produce the Debug host app.
3. Install with `rm -rf /Applications/Ghostty.app` followed by `ditto macos/build/ReleaseLocal/Ghostty.app /Applications/Ghostty.app`.
4. Unregister the temporary build app after copying it, because xcodebuild registers it with LaunchServices: invoke `lsregister -u "$(git rev-parse --show-toplevel)/macos/build/ReleaseLocal/Ghostty.app"`, then remove that temporary app bundle. Also unregister/remove stale DerivedData Debug and Release Ghostty.app bundles when they exist.
5. Run `lsregister -gc`, then register only `/Applications/Ghostty.app` with `lsregister -f -R -trusted /Applications/Ghostty.app`.
6. Verify the installed bundle with `plutil -p /Applications/Ghostty.app/Contents/Info.plist`; require `CFBundleIdentifier = com.mitchellh.ghostty` and no `[DEBUG]` display name.
7. Verify the installed bundle with `codesign --display --verbose=1`; confirm universal `arm64 + x86_64` when relevant.
8. Do not use Xcode `Debug`, Xcode configuration-only builds, or `zig-out/Ghostty.app` as the delivery artifact.
9. If the app was already running, tell the user to fully quit and relaunch it so macOS does not keep the old process. Reopen System Settings after registration cleanup to refresh its cached extension list.
10. Commit source changes after verification when the user asks to commit.
