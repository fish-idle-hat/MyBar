# Readiness research — 26 October 2026

Primary product documentation, not independent clinical validation. Product
availability varies by model/region and may change.

## Apple Watch

Apple's current Readiness app (Series 12 / Ultra 4) gives a 0–10 score from:

* Activity: recent/current active calories, workout effort and training load.
* Vitals: overnight heart rate, respiratory rate, wrist temperature, HRV and
  available blood oxygen, plus daytime heart rate, compared with a personal
  baseline. Setup requires at least seven nights wearing the watch to sleep.
* Sleep: last night's and recent sleep scores.

The score updates during the day. Categories are Recover (0–1), Pace Yourself
(2–4), Ready (5–7) and Go For It (8–10). Apple describes general wellness and
activity capacity, not a measurement of happiness or work performance. The
documentation does not publish reproducible scoring coefficients. TheBar must
not claim to implement Apple's proprietary algorithm.

Sources: [Apple Watch user guide](https://support.apple.com/guide/watch/readiness-flx4gnzby346/watchos),
[Apple's calculation overview](https://support.apple.com/en-us/128112).

## Other approaches

| Product | Inputs and useful design lesson | Limitation for TheBar |
| --- | --- | --- |
| [Oura Readiness](https://support.ouraring.com/hc/en-us/articles/360025589793-Readiness-Score) | Sleep, resting heart rate/timing, body temperature, HRV and activity. Balance contributors compare weighted 14-day trends with a roughly two-month baseline. Compare people with themselves, not a universal ideal. | Ring-based recovery, not a direct mood/productivity measure. |
| [WHOOP Recovery](https://www.whoop.com/us/en/thelocker/how-does-whoop-recovery-work-101/) | HRV, resting heart rate, sleep and respiratory rate. Recovery is contextualized alongside physical strain. | Wearable physiological data; cannot be inferred from Mac CPU/fan data. |
| [Athlytic](https://athlyticapp.helpscoutdocs.com/article/13-getting-started) | Apple Health overnight HRV and resting heart rate compared with a 60-day rolling baseline; 0–100 recovery plus journal/impact analysis. | Needs Apple Health/Watch data; recovery does not certify cognitive performance. |
| [How We Feel](https://howwefeel.substack.com/p/coming-soon) | Repeated self-reported emotion check-ins reveal patterns and support reflection. | Subjective reports are the evidence for mood, not something to silently replace with behavioural guesses. |

## Implications implemented in TheBar

Keep **focus readiness**, mood, stress load and energy distinct. Use opt-in Mac
behaviour only as weak contextual evidence; never use chip temperature, fan RPM,
CPU load or GPU load as human biological measurements. Activity can mean gaming,
reading or meetings, and input-idle is not necessarily rest. Do not call a
percentage an accuracy or success probability. Show unavailable data honestly,
require a baseline, label estimates, accept explicit feedback, validate changes
chronologically, and revert harmful updates. Explain recommendations rather than
only showing a score. Do not train on the algorithm's own predictions as truth.

No wearable integration was added in this change. Apple's HealthKit framework
does not let a native macOS app read/write HealthKit data. A future integration
would need a separately authorized supported-device companion/import workflow;
the user's approval and a privacy design would be required first.
[Apple HealthKit availability](https://developer.apple.com/documentation/healthkit/hkhealthstore/ishealthdataavailable()).

Weekly local model review and bounded histories are already part of Mood Compass.
They can improve agreement with personal reports, but neither this research nor
a successful validation split guarantees that a future emotional state or
productive day can be predicted accurately.
