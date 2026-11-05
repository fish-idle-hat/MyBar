# Build 17 — typing sound picker appearance fix

2026-10-28. Scope: Sound → Typing Feedback → mechanical switch choices.

The layer background was converted from a semantic NSColor to a fixed CGColor
when the picker was created. It could retain the app's dark appearance after
being attached to a light status-item menu, while its native button text became
black. This produced the dark-on-dark choices in the reported screenshot.

The picker now resolves its background/border in its own effective appearance,
refreshes when attached or when the inherited appearance changes, and explicitly
uses semantic label colors for choice titles. No new timer or polling was added.
Choice tooltips no longer cover adjacent rows; the descriptions remain available
to accessibility. All eight choices and the selected checkmark are preserved.

Validation: 168 optimized-release tests, no failures or skips; Swift warnings
treated as errors. Added light → dark → light inheritance/contrast tests (at
least 4.5:1), choice bounds/tooltip tests, plus the existing selection-across-
refresh regression. Both appearances were rendered for visual inspection.
Packaged signature, Pet assets, keyboard recordings, broken-pipe isolation and
menu-helper quarantine checks passed.

No audio rendering/routing, volume preference, keyboard listening policy, fan
control or Pet functionality was changed. Pet development remains paused.
The original build 16 release folder is retained. As with other ad-hoc updates,
the installed build may require refreshing its existing Input Monitoring entry;
do not reset all permissions or weaken signing requirements.
