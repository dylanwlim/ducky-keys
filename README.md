# Ducky Keys

A small native Mac menu bar app for Ducky keyboards. Left Control becomes Command, and the left Windows key becomes Control. Right-side modifiers stay unchanged.

Made by [Dylan](https://dylanwlim.com).

## Use

Download **Ducky-Keys.zip** from [Releases](https://github.com/dylanwlim/ducky-keys/releases/latest), unzip it, move **Ducky Keys.app** to Applications, and open it. Requires macOS 13 or later, on Apple silicon or Intel.

Click the keyboard icon in the menu bar:

- **Swap Control and Windows** pauses or enables the mapping.
- **Bluetooth Keyboard…** lets you enter the exact name if you renamed your Ducky.
- **Start at Login** keeps it ready after signing in.
- **Check for Updates** is intentionally disabled. Download updates from GitHub.
- **About Ducky Keys…** includes the clickable author link.

Ducky-named external keyboards are detected automatically over Bluetooth, USB, and a wireless receiver. The known USB ID `3233:0018` is also recognized. A receiver with a different ID and no Ducky name is not automatically selected. Bluetooth and receiver modes can expose different identities.

Pause or quit to restore the prior Control/Windows mapping. Disconnecting the keyboard clears its temporary macOS mapping. The built-in keyboard and virtual keyboards are excluded.

## Privacy and behavior

No key logging, input interception, driver, background helper, network requests, or third-party dependencies. The app uses Apple's per-device `UserKeyMapping` property and reads it back to verify the change. It watches device arrival/removal and refreshes after wake. Preferences and a crash-recovery mapping journal stay on your Mac.

Quit or uninstall other key remappers before use. Start at Login begins after you sign in; it does not remap the pre-login or FileVault screen.

## Signing

The current build is ad-hoc signed, not Developer ID signed or notarized. macOS may block a downloaded copy. Follow macOS's normal app approval flow only if you trust this source, or build it locally. No security settings need to be disabled. A future notarized distribution requires a Developer ID Application certificate and Apple notarization credentials.

## Build and test

With Swift 6 and the macOS SDK installed:

```sh
swift test
./scripts/build.sh universal
```

The universal app and ZIP are written to `dist/`. For a local-architecture build, run `./scripts/build.sh`. Set `SIGNING_IDENTITY` to use an available signing certificate. Notarization is a separate distribution step.

Read-only local diagnostics:

```sh
'/Applications/Ducky Keys.app/Contents/MacOS/DuckyKeys' --diagnostics
```

## Implementation

The small AppKit app calls public IOKit APIs documented in [Apple TN2450](https://developer.apple.com/library/archive/technotes/tn2450/). It changes only the selected physical keyboard services, merges unrelated mappings, and restores owned entries on pause/quit. A journal scoped to the boot session, registry ID, and device fingerprint supports recovery after an unexpected exit.

Automated tests cover filtering, readback verification, pause/quit restoration, failed writes, conflicting remappers, reconnects, and crash recovery. Physical Bluetooth and dongle keypress behavior should be checked on the actual keyboard.
