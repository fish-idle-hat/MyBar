# Trackpad Gestures — MyBar (source correction after build 19)

## Use and permissions

Open MyBar's existing dropdown → **Settings… → Trackpad Gestures**. This project
uses AppKit, so the settings are a native NSWindow with standard controls and the
existing hover segmented control; no SwiftUI migration or new dashboard tab.

* **Enable Four-Finger Tab Switching** defaults **OFF**. Settings persist under
  the single `MyBar.TrackpadGestures.v1` UserDefaults key. Corrupt settings fail off.
* Low / Medium / High require approximately 18% / 12% / 8% of trackpad width.
  Reverse Swipe Direction is optional. By default physical left means next tab,
  physical right means previous tab, independent of natural-scroll preferences.
* Lift all fingers once after activation/reconnection to arm. Put exactly four
  fingers down together, move horizontally, then release. One completed swipe
  yields at most one switch. A 300 ms cooldown prevents duplicates.
* **Accessibility** is needed to post native browser shortcuts. MyBar checks both
  AX trust and posting permission; it does not prompt on launch or automatically
  grant anything. Open Accessibility opens the OS pane for the user to authorize.
  This feature does **not** request Input Monitoring, Automation, Screen Recording,
  microphone, location or administrator access. Existing typing-sound permissions
  belong to that separate feature and are not changed here.
* System Settings → Trackpad → More Gestures → **Swipe between full-screen apps**:
  four-finger horizontal desktop switching must be disabled for every trackpad.
  Selecting Three Fingers can leave both three- and four-finger mappings enabled
  on macOS 27. Use Off if necessary, or explicitly approve the narrowly scoped
  setup described below. Click Recheck afterward. The app never changes system
  gesture preferences automatically.

The physical test of installed build 19 disproved its assumption that
`three=2, four=2` frees four fingers: the swipe still switched desktops/apps.
The corrected source treats any known nonzero four-finger mapping as reserved,
regardless of the three-finger value. Only `four=0` is clear. Missing/unsupported
values remain unknown; a known global value or known values for both devices are
required for availability. These preferences are private and version dependent.

### Explicit one-time setup (requires user approval)

`scripts/configure-four-finger-mapping.swift` defaults to a **read-only dry run**.
It changes only the four-finger horizontal mapping in the built-in/Bluetooth
any-host scopes and the current-host global scope. It preserves three-finger
switching, other gestures and app permissions; this disables the macOS four-finger
desktop action globally, including outside browsers. It does not suppress events.

```sh
swift scripts/configure-four-finger-mapping.swift
# Only after explicit approval; choose a NEW backup filename:
swift scripts/configure-four-finger-mapping.swift --apply /absolute/path/backup.plist
# Restore the exact saved four-finger values if still unchanged since setup:
swift scripts/configure-four-finger-mapping.swift --restore /absolute/path/backup.plist
```

The script requires three-finger desktop switching already configured in all
three scopes, refuses unexpected host overrides, writes a mode-0600 backup without
overwriting an existing file, uses Apple's `activateSettings -u` to reload, checks
readback, and rolls back on failure. It does not restart Dock or MyBar. This is a
reviewed setup tool, not an app-launch action or background permission bypass.
The native preferences/reloader approach follows
[SwipeSwitcher's implementation](https://github.com/haonlabs/SwipeSwitcher/blob/main/Sources/SwipeSwitcher/GestureConflict.swift)
(MIT; see THIRD_PARTY_NOTICES). Physical testing remains required.

## Browser shortcuts and focus

Only these stable foreground bundle identifiers qualify:

| Browser | Bundle identifier | Next / previous shortcut |
| --- | --- | --- |
| Microsoft Edge | com.microsoft.edgemac | Command-Option-Right / Left |
| Google Chrome | com.google.Chrome | Command-Option-Right / Left |
| Safari | com.apple.Safari | Control-Tab / Control-Shift-Tab |
| Firefox | org.mozilla.firefox | Command-Option-Right / Left |
| Brave | com.brave.Browser | Command-Option-Right / Left |

Firefox uses positional arrows rather than Control-Tab because Control-Tab may
cycle in recently-used order. Chromium-family Edge uses the same positional arrow
accelerator as Chrome/Brave; confirm this on the installed Edge version. Browser
custom shortcuts/extensions, modals and devtools can affect native handling.
With only one tab there may be no visible change. MyBar cannot acknowledge the
browser's actual tab switch without additional inspection, which is not performed.

NSWorkspace activation/quit notifications maintain only a transient allowlisted
PID/browser identity. Every activation, setting or lifecycle change invalidates
the gesture generation. A reply must match that generation, be no older than
500 ms, pass cooldown, and still match the foreground PID/bundle. The dispatcher
rechecks immediately before posting key-down/up **to that PID**, never the global
event stream. It never calls browser activation, changes focus, enumerates tabs,
reads URLs/titles or records browsing history. Secure Input, held shortcut modifiers
and mouse-button dragging suppress switching. There is no Command-Tab shortcut.

## Detection, isolation and lifecycle

Public AppKit swipe/touch handling is associated with an app's windows; scrolling
does not identify four stable contacts and cannot reliably override a reserved
global system swipe. A narrow dynamically loaded **private MultitouchSupport**
bridge is therefore packaged **only** in `local.mybar.trackpadhelper`.
The main monitoring process does not link or load this bridge.

The helper is a MyBar-owned unprivileged executable inside the same application,
not a third-party app, login item, daemon or privileged fan helper. It is created
only when this feature is enabled, permissions are available, the session is active
and system conflict checks pass. Outside supported browsers the helper can remain
idle for device notifications but unregisters/stops touch callbacks.

* Device list discovery supports framework-exposed built-in and external/Magic
  Trackpads. IOKit arrival/removal notifications trigger a coalesced rescan, not
  polling. Recheck is available if a device/OS does not issue usable notifications.
  Device count is the framework's multitouch-device count, not a guarantee that
  every enumerated device can emit four contacts.
* The bridge checks required symbols, compile-time 96-byte touch ABI, finite/range
  values and bounded device/contact counts. ABI checks cannot certify a future OS.
  Only making/touching contacts are counted, never hover or liftoff states.
* Each physical device has its own identity-tracking recognizer. Exactly four
  stable IDs must translate coherently. Fifth/replacement fingers, large vertical
  excursions, pinch/rotation, non-finite/out-of-range input, stale frames,
  overlong strokes, slow finger assembly and re-landing cancel until full lift.
  Slightly staggered liftoff is tolerated for at most 180 ms; taps never qualify.
* Callback work runs on framework threads behind a short lock, not on the main
  thread. Only completed gestures and availability/error messages reach MyBar;
  raw contacts never cross the process boundary or get persisted/logged.
* Bounded JSON-lines on inherited stdin/stdout pipes carry configuration and
  completion messages. Each message is at most 1 KB, parsing is bounded, writes
  are nonblocking, and single POSIX reads consume available bytes immediately.
  No network, public sockets, continuous timers or keyboard event listener.
* Sleep, display sleep, session resignation/lock and normal quit stop the helper;
  wake/unlock reconciles preferences and requires a fresh stroke. A session-state
  check also guards completion dispatch. Notification/key compatibility is subject
  to macOS changes.
* Disable closes the helper pipe; the helper unregisters devices on EOF. An
  unresponsive **owned trackpad child only** gets TERM after one second and, if
  still alive, KILL after three seconds. MyBar and audio/fan helpers are never
  terminated by this mechanism. Startup has a five-second deadline. Failure
  latches an unavailable status until Recheck/settings change; no restart loop.

No trackpad events are swallowed, including outside supported browsers. If an OS
or browser emits ordinary scrolling alongside four-finger raw frames, that remains
a physical-testing limitation; MyBar does not add a broad scroll-blocking tap.

## Compatibility and distribution

Private APIs may change or disappear without notice. The symbol probe only
confirms symbol availability, not real contact delivery, gesture feel or hardware
compatibility. A private-framework crash is contained in the child, but a future
ABI change may require disabling/updating this experimental feature.

This build is **not suitable for Mac App Store submission**: isolating private
APIs in a helper does not make them public. The local package uses the project's
existing ad-hoc signing and is not a notarized/public release. Replacing the
installed app may invalidate its existing Accessibility/Input Monitoring grant;
keep `/Applications/MyBar.app` as the canonical path and refresh permissions only
with the user's approval. Do not run multiple copies with the same bundle ID.

## Source changes

| File | Change |
| --- | --- |
| Package.swift | Core/C bridge/helper targets; app and test dependencies |
| Sources/TrackpadGestureCore/TrackpadGesture.swift | Pure recognition, settings, bounded IPC schema/framing |
| Sources/CTrackpadBridge/include/CTrackpadBridge.h | Narrow callback interface |
| Sources/CTrackpadBridge/CTrackpadBridge.c | Dynamic private ABI bridge, device registration/cleanup |
| Sources/MyBarTrackpadHelper/main.swift | Off-main recognition, device notifications, pipe service, probes |
| Sources/ThermoBar/BrowserTabDispatcher.swift | Browser allowlist/mappings, focus/permission guards, read-only conflict check |
| Sources/ThermoBar/TrackpadGestureManager.swift | Preferences, lifecycle, isolated process supervision and dispatch |
| Sources/ThermoBar/TrackpadGesturesSettingsView.swift | Native settings view/window and existing hover treatment |
| Sources/ThermoBar/AppDelegate.swift | Start/stop service; Settings… menu action |
| Tests/ThermoBarTests/TrackpadGestureTests.swift | Recognition, dispatch, permissions, IPC/failure, settings/render and cost tests |
| scripts/build-app.sh | Build, embed and sign owned helper |
| scripts/verify-release.sh | No-monitoring helper protocol smoke check |
| Resources/Info.plist | Build 19 |
| THIRD_PARTY_NOTICES.md | SwipeSwitcher MIT attribution/license |
| docs/TrackpadGestures.md | Setup, design, limits, sources and changed-file list |

Pre-change recoverable archive:
`outputs/archive/MyBar-before-TrackpadGestures-20261103.tar.gz` (workspace root).
Final test counts, measurements and deployment state are recorded alongside the
candidate package, not inferred from a successful compile.

## Physical acceptance still required

On both a built-in and Magic Trackpad, verify left/right once per lift at each
sensitivity, staggered landing, diagonal/vertical gestures, pinch, one/two/three/
five fingers, typing/dragging, rapid strokes, holding/reversing, browser changes
mid-stroke, each of the five browsers, quitting a browser, sleep/lock/wake, device
disconnect/reconnect, revoked permission and system conflicts. Check that no
Spaces/window/app switching or unwanted page scrolling occurs, and that focus
stays in the original browser field. No genuine four-finger frames or actual
browser key injection are generated by automated tests.

## Primary references reviewed

* [SwipeSwitcher source and MIT license](https://github.com/haonlabs/SwipeSwitcher),
  reviewed commit c76041d9dde59815ec42d22f30a1a0532c51d3aa on 2026-11-03.
  Only contact ABI/declarations were adapted; full credit/license is bundled.
* [Apple NSEvent](https://developer.apple.com/documentation/appkit/nsevent)
  and [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)).
* [Chrome shortcuts](https://support.google.com/chrome/answer/157179),
  [Firefox shortcuts](https://support.mozilla.org/en-US/kb/keyboard-shortcuts-perform-firefox-tasks-quickly),
  [Brave shortcuts](https://support.brave.app/hc/en-us/articles/360032272171-What-keyboard-shortcuts-can-I-use-in-Brave),
  [Edge shortcuts](https://support.microsoft.com/en-us/edge/keyboard-shortcuts-in-microsoft-edge).
  Never use the Edge page's ambiguous Command-Tab entry, which macOS reserves
  for app switching. Positional Chromium arrows require physical Edge confirmation.
* [Safari shortcuts](https://support.apple.com/guide/safari/keyboard-and-other-shortcuts-cpsh003/mac)
  (the web fetch was rate-limited during this review; physical verification remains required).
* [Apple App Review Guidelines §2.5.1](https://developer.apple.com/app-store/review/guidelines/).
