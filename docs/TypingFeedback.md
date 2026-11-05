# Typing Feedback

Sound → Typing Feedback. Off by default. Use the in-panel sound list to select an
mechanical switch recording, choose a gentle volume, and press Preview. Manual preview does not
require Input Monitoring or enabling automatic key feedback. It prepares only
the confirmed Bluetooth-headphone route. Without an authorized key listener,
the preview stream stays warm for up to eight seconds after a preview and closes
when the menu closes. It never turns on keyboard monitoring. This bounded warm
window avoids repeatedly cold-starting Bluetooth between audition clicks.

Automatic key feedback requires enabling the checkbox and approving Input
Monitoring if macOS asks. If it is missing, **Allow typing…** opens the permission
request/settings rather than disabling sound selection and preview. Retry checks
permission after approval; macOS may require Quit & Reopen. Accessibility
permission may also allow the passive event tap. No permission is silently granted.
The sound list uses inline buttons, not a nested NSMenu, so polling refreshes do
not interrupt its selection. It closes when a sound is chosen or the menu closes.

## Safety and privacy

* Only the current system output is considered. It must be Bluetooth/Bluetooth
  LE and report a headphone stream terminal. Known speaker terminals and wired,
  USB, built-in, virtual or missing outputs are rejected. An unknown Bluetooth
  terminal requires explicit confirmation that it is headphones; the decision
  is tied to that device UID, not a name guess. A known speaker cannot be
  overridden by that confirmation.
* Output is bound to the physical AudioDeviceID with its own IOProc, not a player
  following the default output. Switching to speakers cannot move the click
  stream to speakers. Route-change listeners stop the stream; stale clicks over
  50 ms old are dropped, never replayed after reconnecting.
* The helper disables its input streams before starting the device. It does not
  capture microphone/system audio, create a process tap, change hardware volume,
  unmute headphones, or change the system output. Unsupported formats fail closed.
* A listen-only key-down tap triggers clicks without reading characters, key
  codes, target apps or typed strings. Nothing is recorded. Secure-input fields
  stay silent; auto-repeat and Command/Control shortcuts do not trigger clicks.
  The tap is removed while disabled, asleep/inactive, waiting for headphones,
  or when audio preparation fails. OS-disabled taps require an explicit retry.
* Typing activity is not added to Mood Compass or its data/history. Preferences
  retain only enabled state, sound, volume, and at most 16 confirmed output UIDs.

## Latency, resource use and isolation

Eight switch packs replace the macOS notification sounds: Gateron Ink Red,
Cherry MX Blue, Cherry MX Brown, Gateron Ink Black, NK Cream, Holy Panda, Alpaca
and Topre. Each has three generic press recordings from Thomas Lai's MIT-licensed
kbsim project, pinned to revision ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4.
The 24 MP3 files total approximately 56 KB and are bundled with their license;
no network access is needed at runtime. Old system-sound preferences migrate to
Gateron Ink Red, preserving enabled state, gain and confirmed headphones.

The selected three recordings are decoded once per sound/output change. Leading
silence/encoder padding is removed with a 0.2 ms pre-transient margin, then each
is converted to a maximum 75 ms stereo click with a 0.2 ms attack and 6 ms release.
Variations rotate per press, not per key identity. The default is Gateron Ink Red
at a low gain; the local gain slider never
changes media/headphone volume. Eight preallocated voices handle fast typing,
with bounded output to prevent clipping and no decoder or filesystem work in
the audio callback. Memory use is bounded; no samples/history accumulate.

Manual previews always use the same first recording, with a reserved voice that
ignores retriggers while that click is playing. Preview clicks therefore cannot
stack or randomly change variations/volume. Seven other voices remain available
for automatic typing. A newly opened output is primed with silence for 200 ms
before READY; this is one-time preparation, not a delay on individual keys.

All recordings are peak-matched to 0.85 after trimming/fades, before the user's
feedback gain. This raises quiet recordings (especially Topre) without changing
headphone/master/music volume. Amplification is capped at 32x, and the renderer's
0.85 output limit still applies to overlapping clicks. No per-key normalization
or additional render-time processing is needed.

Development builds are ad-hoc signed; their code requirement changes when the
executable changes. macOS can therefore reject a permission granted to an older
build even when Settings still displays TheBar as enabled. Toggle its Input
Monitoring permission off/on (or remove/re-add this exact app), then Quit & Reopen
if macOS requests it. The menu rechecks a waiting permission when reopened, without
polling or showing unsolicited prompts. The app never resets TCC or weakens its
signature requirement to bypass approval. A consistent trusted code-signing
identity is needed to retain grants reliably between development updates.

A dedicated user-interactive thread runs the passive event tap independently of
the UI/main run loop. It immediately sends a stack-allocated, nine-byte nonblocking
datagram per physical key-down, with no main-queue hop or timer batching. It drops
work if the receiver is busy rather than blocking typing or queuing delayed
sounds. Rendering occurs in `local.thermobar.typinghelper`, a separate unprivileged
process. Crashes/timeouts disable feedback and show a status without terminating
TheBar or touching existing sound routing. There is no automatic crash/restart
loop. A watchdog ends the helper if the parent dies. No event tap or automatic
audio stream runs while disabled; an explicit one-shot preview is the exception
and is released automatically. Device monitoring is event-driven; the active
helper performs a two-second parent/route safety check, not a process-wide scan.

While enabled and ready, the headphone output is kept primed for quick first-key
response. This can keep a Bluetooth audio connection awake and consume additional
headphone power; turn the feature off to release it. Bluetooth and macOS hardware
buffers still add latency, so zero end-to-end delay cannot be promised. The
device buffer settings are not changed globally, because doing so could interrupt
music or other audio apps. The opt-in synthetic renderer and IPC benchmarks
exclude Bluetooth transport, device startup and OS audio-service costs; they are
not measured acoustic latency. A computer key-down event also does not expose the
exact physical moment a key bottoms out, and the app cannot predict future keys
to compensate for Bluetooth delay.

## Verification

`TypingFeedbackTests` verifies transport/headphone policy, confirmation isolation,
default-off behavior, no off-state permission/output queries, corrupt preference
sanitization/migration, fresh fixed-size/stack packets, all 24 bundled recordings,
sub-millisecond sample onset, silent idle, rotating variations,
route invalidation clearing old voices, bounded overlap/interleaved output,
helper process failure containment, UI controls in both appearances, and an
opt-in render benchmark. No tests inject keystrokes or play sound to hardware.
Existing fan, sound-routing, system-tab and Mood Compass regressions also run.

Real permission approval and perceived Bluetooth latency require a manual test
with the user's headphones. This is distinct from silent/offline test coverage.
The packaged helper's `--validate-sounds` mode decodes every bundled recording
without opening an audio device or installing a keyboard listener.
