# Mood Compass

Open TheBar → Mood Compass. This is the existing TheBar application, not a new
application named MyBar. Monitoring is **off by default**. Press Start, then
choose additional data sources under Privacy. Existing tabs and data are retained.

## What the feature does—and does not know

Energy, stress load and focus readiness are experimental **behavioural estimates**
on a 0–100 scale, not emotional measurements, diagnoses or medical advice.
The initial model uses conservative workload/break heuristics. Mood balance stays
**Uncalibrated** until sufficient self-reports and a validated weekly model update
exist. No history is fabricated. Your own self-report always takes precedence.

Signals and limitations:

* Activity: aggregate app-switch counts, input-active time and idle breaks.
  No app names, bundle IDs, window titles or document contents are stored.
  Input-idle can mean reading or attending a meeting; it is not proof of resting.
* Typing: poll the system's **aggregate event counter**, never key events, key
  codes or characters. Only per-window count and count-variation features remain.
  Secure-input periods, counter resets and implausible bursts are excluded when
  detected. This is not a keylogger and cannot read what you type.
* Music: whether a recognized music player is currently producing output. No
  audio capture, titles, genres or playback history is fetched. Music in browser
  tabs, unsupported players and headphones disconnected from the Mac may not be
  identifiable. Playing audio does not prove you are listening or reveal mood.
* Calendar: busy-time union in the next two hours, excluding free/cancelled and
  all-day events. Event text, attendees and locations are neither accessed by
  feature code nor saved. Excessively large query results are treated as missing.
* Reminders: bounded counts of today's completed and due reminders. No titles or
  task contents are persisted. No tasks or calendar events are modified.
* Daylight: an occasional coarse Core Location fix is converted immediately to
  an approximate daylight flag using local solar calculations. Coordinates are
  not retained or transmitted by TheBar. This does not measure weather, actual
  room lighting, physical location labels or whether you are outside.
* Optional Home / Work-study / Travelling / Resting context is chosen by you,
  not guessed from your location. Local hour supplies a circadian-context signal.

## Permissions

Sources are individually opt-in. Activity needs no additional permission.
Typing requires macOS Input Monitoring or applicable Accessibility access.
Calendar and Reminders need EventKit full-access permissions: macOS does not
offer a read-only authorization level even though this feature only reads.
Daylight requires Location Services. A menu-bar app may need foreground activation
to present that prompt. Denied or revoked sources remain missing—not zero—and
never prevent the rest of TheBar from working. Use Privacy → Permissions or
System Settings → Privacy & Security to manage authorizations. Local development
build signing changes can cause macOS to ask again.

Apple references:
[aggregate input counters](https://developer.apple.com/documentation/coregraphics/cgeventsource/counterforeventtype(_:eventtype:)),
[EventKit access levels](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
[Core Location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services).

## Personal learning and safety

The deployed Swift algorithm runs locally while TheBar is open. Codex is not
involved in runtime monitoring or model updates, and no deployed code is rewritten.

1. Bounded, slowly adapting means/variances establish individual behavioural
   baselines. Missing, non-finite, out-of-range, duplicate-time and interrupted
   samples are rejected or omitted. Sleep/lock time and long gaps do not count as
   observations. Baselines are not emotional labels.
2. Optional 1–5 check-ins pair actual self-reports with the **previously issued**
   estimate and features. Check-ins are rate-limited. A focus session freezes its
   start prediction; after 5 minutes (within 2 hours), its actual outcome can be
   rated. Later features do not replace session-start features.
3. After at least seven elapsed days **and seven observed days**, the app reviews
   the data automatically. With fewer than 32 usable feedback outcomes across
   four days, it records a review but keeps the scoring model unchanged.
4. A small regularized linear candidate trains on the earlier 75% of recent
   feedback; the later 25% is held out. Each changed output requires 16 training
   labels and four validation labels. Bias shifts are limited to five points;
   each coefficient changes by at most three. Estimates are clipped to 0–100.
5. The candidate needs at least a one-point / 3% holdout improvement (whichever
   is larger), with no output worsening by more than two points. Otherwise it is
   rejected. A provisional update retains its predecessor.
6. At least eight new outcomes per changed output across two days validate the
   provisional update. If aggregate or per-output error exceeds the predecessor
   by more than 10% plus two points, it is **automatically rolled back**. Another
   adjustment cannot bypass pending validation. Review history distinguishes
   held steady, rejected, provisional, confirmed and rolled-back changes.

Observed error is mean absolute disagreement with actual feedback, **not an
accuracy percentage**. Behaviour and subjective mood are noisy; improved validation
does not guarantee future accuracy, causal insight or clinical validity. New habits
adapt slowly through the baseline, recent feedback window and bounded updates.

## Performance and storage

* No cloud calls or background Codex dependency. Nothing is collected while paused.
* Approximately one sample/minute; optional keyboard-counter polling every ten
  seconds. Calendar/reminder context is cached for ten minutes. Location is a
  coarse one-shot request, not continuous GPS tracking.
* No process-wide CPU scans or audio capture are added. Music checks only the
  Core Audio process list once per sample when enabled.
* Model fitting and binary-plist persistence use a utility queue; UI draws only
  on change. There is no continuously running animation or inference loop.
* Five-minute trend buckets for seven days (at most 2,017), daily summaries for
  180 days, at most 512 feedback outcomes, 104 review entries and eight previous
  models. Graphs draw at most about 180 sampled vertices per metric.
* History is atomically saved about every five minutes, immediately after
  feedback, and on a normal quit. A crash/force-quit may lose recent unsaved
  samples, not the entire history. Corrupt/incompatible files are not overwritten.
* Storage: `~/Library/Application Support/ThermoBar/MoodCompass/state-v1.plist`.
  Mood storage uses a private directory and mode-0600 file. Original TheBar data
  uses its existing locations and is not migrated or deleted.
* Privacy → Delete all Mood Compass data confirms deletion, stops monitoring,
  removes the local state/models and resets Mood Compass preferences only.
  It cannot revoke macOS permissions for you; those remain under System Settings.

The release-mode `CompassMenuReadinessTests.testBoundedWorkloadBenchmark` probe
on this Mac (26 October 2026) filled 2,017 recent buckets, 180 daily buckets and
512 feedback outcomes. One run averaged **0.042 ms per observation** across
1,000 observations, **103.69 ms for a weekly fit**, and **17.46 ms for an atomic
save**; the binary payload was **186,547 bytes**. These are synthetic engine/I/O
measurements, not whole-app CPU usage or a guarantee for other machines. Native
permission services and optional calendar/location/music queries are outside
that probe. The benchmark is opt-in (`MOOD_COMPASS_BENCHMARK=1`) and leaves no
personal monitoring enabled. Production still performs only one observation per
minute and saves about every five minutes. Training precomputes eligible labels
and predicts only the metric currently being fitted. Hardware refreshes do not
redraw Mood charts; the readiness payload contains no historical arrays.

No automatic launch-at-login or separate daemon was added. While the app is quit,
there are no samples or weekly reviews; retained progress resumes when reopened.

## Verification

`MoodCompassTests` covers invalid/missing input, default-off behaviour, cold-start
honesty, baseline adaptation, compact history, check-in validation, frozen focus
outcomes, review scheduling, chronological rejection, bounded acceptance,
automatic rollback, private persistence, deletion isolation and all four UI pages
in light/dark appearance. The existing audio and system-monitor regression suite
is also run. Real permissions require the user's approval; they are not silently
enabled as part of verification. Long-term subjective accuracy can only be
evaluated after real check-ins accumulate.

## Readiness on the menu bar

When **every fan has a valid reading of exactly zero RPM**, the left metric is
`RDY`, an estimated focus-readiness score displayed as a percentage in 5-point
steps. The blue 40–80°C thermal-headroom bar, CPU and GPU metrics stay unchanged.
Any spinning or unknown fan restores `TEMP`. A chip temperature of 80°C or above
also restores temperature, so a thermal warning cannot be hidden by readiness.

`—% RDY` means unavailable, not zero readiness. Monitoring must be explicitly
enabled, at least 20 approved behavioural baseline samples must exist, current
signal coverage must be sufficient, and the latest sample must be no older than
three minutes. Time-of-day/manual context alone cannot qualify. Disabling
monitoring immediately removes the number. The tooltip explains availability and
what the bar represents; VoiceOver includes the same explanation and real chip
temperature. No extra timer, sensor poll, model training or disk write is added
to update this metric. Existing hardware refreshes handle expiry and fan changes.

The initial score is a heuristic, **not a validated probability of productivity**.
The 20-sample gate avoids showing a cold-start number; it does not establish
accuracy. Weekly validation and real focus outcomes/check-ins remain necessary.
See [readiness product research](ReadinessResearch.md) for the distinction between
physiological recovery, subjective mood and computer-based focus readiness.
