> **Correction after the physical build 19 test:** The initial interpretation below
> was wrong. The user confirmed that `(three=2, four=2)` still switches desktops/apps.
> Unit tests encoded the mistaken assumption and did not establish hardware success.
> The corrected source requires explicit `four=0`, and the guide describes an
> optional, consent-gated native setup with backup/restore. Build 19 remains the
> installed binary pending setup verification; source changes are not yet deployed.
> See `TrackpadGestures.md`. No system settings were silently changed.

# Build 19 — false four-finger conflict

## Reproduced on the user's Mac

The user enabled Trackpad Gestures, but MyBar stayed paused. The previous local
build's Accessibility grant needed refreshing; re-adding the same installed app
cleared that gate without recompilation. The remaining conflict warning was a
bug in MyBar, not an incorrectly chosen OS option.

System Settings visibly showed **Swipe Left or Right with Three Fingers**. After
the user also explicitly selected Off → Three Fingers, read-only checks still
showed `TrackpadThreeFingerHorizSwipeGesture=2` and
`TrackpadFourFingerHorizSwipeGesture=2` in the built-in and Bluetooth domains.
Build 18 incorrectly treated any nonzero four-finger flag as a conflict. Thus its
own documented Three Fingers setup could never pass on this configuration.

This paired interpretation also appears in a primary upstream gesture-tool
[configuration report](https://github.com/JitouchApp/Jitouch/issues/43) (2022-10-30):
three-finger horizontal selection is distinguished by the three-finger key;
four-finger reservation additionally requires the three-finger key to be zero.
The live System Settings observation, not the report alone, established the
regression on this Mac. No upstream application/code was installed or executed.

## Minimal fix

Read paired three/four values per built-in, Bluetooth and global preference scope:

| Three | Four | Interpretation |
| --- | --- | --- |
| 2 | 2 | Three Fingers selected; allow MyBar four-finger recognition |
| 0 or 1 | 2 | Four-finger system reservation; stay paused |
| any | 0 | Four-finger mapping explicitly off |
| any | 1 | Other four-finger system mapping; stay paused |
| missing/unsupported combination | unknown | Keep conservative unknown status |

Retain current-host precedence, cross-device/global conflict checks and the
read-only nature of preferences. No system preference writes, Dock restart,
permission bypass, touch/shortcut changes or unrelated refactoring.

Files changed from build 18: BrowserTabDispatcher.swift, TrackpadGestureTests.swift,
Resources/Info.plist (19), docs/TrackpadGestures.md, and this note. A regression
test covers the observed `2,2` combination, actual four-finger reservations,
Off, missing values and unsupported values. All other gesture recognition and
helper-isolation behavior remains unchanged.

## Recovery and verification

Recoverable app/source backups are in workspace outputs/archive:
`MyBar-before-TrackpadConflictFix-build18.zip` and
`MyBar-before-TrackpadConflictFix-source-20261103.tar.gz`.

The release folder records final test results, package checks and live deployment
state. Real four-finger contact delivery and browser behavior still require the
user's physical test; neither synthetic tests nor an idle helper prove success.
Preserve the existing enabled setting chosen by the user and restore existing
Input Monitoring/Accessibility grants after installation if needed. Do not
rebuild or replace the installed bundle again after refreshing its permissions.
