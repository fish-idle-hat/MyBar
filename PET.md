# MyBar Pet

**Status as of 2026-10-27: UNDER DEVELOPMENT. Further feature development is
paused at the user's request; resume only when requested.** The existing Pet
remains available, with size and visibility controls. This does not pause the
app's ordinary monitoring or unrelated readiness automation.

Open **System → Pet**. This uses the same hover selector as Overview and Insights.
Show/hide the desktop companion, select its three reactions, adjust size, or use
**Bring back** if it is on another display. Dragging uses native window dragging;
its position is saved on drop. It never wanders, follows the pointer, speaks,
opens pages, sends messages, or controls the fans.

The Live preview reflects real signals. Work/Music/Fans preview buttons affect
only the preview, never system settings or the desktop's actual state.

## Reactions

- Codex working: the supplied Capri working frames with two decorative browsing
  panels. These panels do not show real chat or browsing contents.
- Music playing: headphones lower onto the head, then remain while music plays.
  This follows apps MyBar identifies as music (including Apple Music); arbitrary
  browser audio is not classified as music simply because it makes sound.
- Any valid fan RPM greater than zero: slow green cyber-eye glow and a small
  scan/glitch. This stays on while the measured fans spin. It is not triggered
  by the blue thermal-headroom bar or temperature alone. No high-frequency strobe.
- Reactions compose: work, headphones and eye glow can coexist.

## Privacy and API boundaries

There is no cloud service, AI inference, microphone, screen capture, key listener,
new Accessibility permission, or dependency on the Codex pet being enabled.
MyBar does not patch, restart or modify Codex.

Codex does not provide a stable public desktop pet-activity API here. The optional
adapter opens its local `state_5.sqlite` read-only, obtains at most 16 recently
updated rollout paths using the updated-at index, then incrementally reads at
most 128 KiB per file. Only lifecycle metadata is used; no conversation text,
titles, workspaces or activity history are saved. Missing/unreadable files,
unsupported schema and malformed data fail closed and show unavailable. Local
sessions only; remote/cloud work is not guaranteed. Stale activity expires after
30 minutes, and a closed Codex app never appears to be working.

## Resource bounds

- No polling while hidden/off; pause on sleep, display sleep and session lock.
- Codex polling every 3 seconds with 0.6 second tolerance, serial utility queue,
  a 25 ms SQLite lock deadline, incremental tails, bounded buffers and cursors.
- Music reuses the existing 2-second Sound timer. When Sound is closed it only
  reads playback metadata, without output-device enumeration, pruning volume
  preferences or touching routes. No second audio capture or route is created.
- Fans reuse existing sensor snapshots without forcing full sensor scans.
- Decode/crop the supplied atlas once; cache 12 small frames and release the
  full atlas. Core Animation handles approximately 6 fps sprite loops and slow
  effect animations. No Swift rendering timer or web view.
- Hidden dropdown previews have no animation. Reduce Motion gives static
  equivalents for every state. Hidden desktop windows remove animations too.
- Only opt-in settings, size and dropped position are persisted.

The user-supplied unofficial fan artwork and its rights notice are retained in
the packaged Pet resources; see THIRD_PARTY_NOTICES.md before redistribution.
