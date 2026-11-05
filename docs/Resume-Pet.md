# Pet checkpoint — resume later

**2026-10-27: Under development. Further Pet feature development paused by user
request. Do not proactively resume, change artwork, add chat/AI, or patch Codex.**

Current user-approved surface: **System → Overview / Insights / Pet**, consistent
native hover. Pet has **Show desktop pet** switch, a separate continuous **Size**
slider (75–160%) with percentage, Bring back, optional Codex/Music/Fans sources,
and Live/Work/Music/Fans previews. User said placement is okay because dragging
works. Size was tested then restored to 110%; visibility was left enabled.

Capri is the supplied capri-anime character. Reactions combine without moving
the window: work frames + two browsing panels for Codex work, lowering headphones
for music, slow green cyber eyes while actual fan RPM is positive. Never wander,
follow the pointer, speak, change fans, or display real browsing/chat contents.

Code entry points:

- Sources/ThermoBar/PetActivity.swift — settings and bounded read-only Codex adapter.
- DesktopPetController.swift — non-activating native panel, window autosave,
  lifecycle, opt-ins, in-place size updates.
- PetCanvasView.swift — cached atlas and compositor animations, Reduce Motion.
- PetControlView.swift — user controls, previews and development note.
- AppDelegate.swift/SystemDetailsView.swift — wiring and System subpage.
- SoundControlManager.refreshMusicActivity — read-only background music check;
  never replace it with a route-mutating full Sound refresh while Sound is closed.
- Tests/ThermoBarTests/PetTests.swift — state, privacy/resource bounds, rendering,
  size/visibility, no autonomous movement and shared-hover coverage.

Read PET.md and Audit-2026-10-27.md before continuing. Retain source asset rights.
Ask for the next desired improvement rather than assuming an unfinished feature
is permission to expand scope. A stable signing identity, Codex adapter evolution,
art refinement and broader physical-device testing remain separate future work.

Build/test commands and limitations are in the audit. Keep the canonical app at
/Applications/MyBar.app and preserve bundle/storage identity. Never copy changes
into Codex or reactivate the quarantined menu-hiding helper.
