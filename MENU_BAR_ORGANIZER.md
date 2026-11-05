# Menu Bar Organizer: implementation and compatibility report

## Outcome

**Current safety status:** macOS 27 hiding is disabled. The real menu bar screenshot showed that the private assertion also hid essential system controls despite the configured numeric system-item range and protected bundle allow-list. After releasing the assertion and refreshing window focus, the complete original menu bar was visibly confirmed restored (app menus, selected apps, ThermoBar, clock, Wi-Fi, battery, and Control Center). No further active restrictions were retained.

The packaged helper was made non-executable without changing signed code bytes: deep/strict signature verification still passes, preserving the current app's newly refreshed permission grant. The Hide Selected control was visibly verified disabled. Release packaging now applies the same restriction, and source policy/helper guards additionally reject private activation until compatibility is proven. This is a deliberate experimental-feature rollback, not an installation failure; the currently installed older status text may call the disabled executable "not installed". The normal monitoring app remains running. **85 automated tests pass.**

The permission itself is fixed and was verified through real AX discovery after re-adding the corrected app. The remaining blocker is the unsafe private API behavior on this OS, not additional user permissions. Hiding and active-crash recovery are not claimed complete. The historical implementation details below describe the attempted approach, not an enabled feature.

This build contains an opt-in **isolated experimental helper for macOS 27**, plus a conservative native-placement fallback on older systems. Direct transfer of an external status item into the dropdown is not implemented. The full original specification is **not verified complete**.

Use **+ Manage** above the existing tabs and enable Accessibility for real-item discovery and verification. On macOS 27 select third-party apps, then **Hide Selected**; no divider/dragging is required. Hiding is per owning app, including multiple icons from the same app. On older systems click **Prepare**, Command-drag real icons horizontally left of `|`, keep ThermoBar right of it, then **Verify & Hide**.

If placement or visibility cannot be verified, the operation refuses or rolls back. **Only verified-hidden items appear as icons in the dropdown.** A saved selection that is still visible is labelled `N selected · Not hidden`; the choices remain available in Manage. Selection must never look like a successful transfer.

### macOS 27 compatibility correction

The previously shipped UI displayed selected app icons even when their originals remained visible. That is corrected. The older divider relied on per-item windows that the shared menu bar no longer exposes, and its disposable-item hiding probe failed here. macOS 27 now uses a separate helper instead.

With the user's explicit approval, `ThermoBarMenuHelper` adapts the runtime bridge described by [MenuBarHider](https://github.com/happy666End/MenuBarHider/blob/main/MenuBarHider/Services/MenuBarAgentBridge.swift), under MIT attribution. It uses undocumented `MenuBarClientCore` assertions and a system-wide allow-list. Only the child process loads/messages the private framework; the monitoring app exchanges bounded JSON over private pipes. No root helper, LaunchAgent, system file changes, security bypass, or new entitlements are used.

The allow-list includes all running app IDs and discovered owners except explicitly selected third-party apps. Apple owners, ThermoBar, and system-item identifiers 0–63 are protected. New app launches release the restriction rather than accidentally excluding the new app. A successful API reply is not enough: the parent re-reads AX positions, requires selected originals to disappear and observed unselected items to remain, and checks that source apps still run. Failed or unverifiable results release the restriction.

The child releases on stdin EOF, SIGTERM/SIGINT, parent loss, eight-second heartbeat expiry, layout/app changes, and activation timeout. It needs no persistent installation. The parent also contains child failures and kills an unresponsive child after one second. **Actual WindowServer restoration after an active-helper crash is still a live acceptance check, not inferred from unit tests.**

Known private-API side effect: the reference project reports interference with Notification Center while its assertion is active. ThermoBar conservatively releases the assertion when the pointer enters the clock/system area (a cheap 4 Hz position check, no global event tap). This deliberately reveals icons and does not auto-rehide them. This mitigation and multi-display behavior need manual verification.

## Feasibility evidence

- Apple's `NSStatusItem` controls the creating application's own item. `NSDraggingDestination` requires a source drag session and supported pasteboard types; those APIs do not define a general external status-item transfer format. We did **not** observe or claim an actual external Command-drag delivery to a third-party destination. A normal `.onDrop` is insufficient evidence.
- Ice's status-item manager uses a private event field (`CGEventField(rawValue: 0x33)`) and explicit window identifiers for synthesized movement/activation; its bridging layer declares private CGS functions. Its section control expands a status item's length to create an offscreen hidden section. These mechanisms explain why moving an item is distinct from copying its image.
- Ice 2 documents native Command-drag along the menu bar, separate hidden sections, Accessibility and Screen Recording requirements, and a manual testing boundary for live status items.
- Thaw separates AX discovery into a service and bounds AX messaging timeouts. Its source is GPLv3. This implementation uses its own small discovery queue with bounded AX requests; no source code from these projects was imported and no dependency was added.

Primary references:

- [Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Apple NSDraggingDestination](https://developer.apple.com/documentation/appkit/nsdraggingdestination)
- [Apple AX attribute mutability](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable)
- [Ice movement implementation](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift)
- [Ice section control](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/ControlItem/ControlItem.swift)
- [Ice private bridges](https://github.com/jordanbaird/Ice/blob/main/Ice/Bridging/Shims/Private.swift)
- [Ice 2 requirements and interaction guide](https://github.com/teddychan/ice-2-macos)
- [Thaw AX service entry point](https://github.com/thaw-app/Thaw/blob/development/MenuBarItemService/main.swift)

No private CGS/SLS interfaces, undocumented event fields, synthetic mouse dragging, screen capture, or global input monitoring are used. The macOS 27 helper does use the explicitly approved private `MenuBarClientCore` runtime API.

## Components and changed files

- `MenuBarOrganizer.swift`: item identity, Accessibility discovery, opt-in selection, persistence, native divider visibility, activation, and recovery. Scans run on a utility queue only on request/menu opening. Discovery has 150 ms AX timeouts. Only a cheap permission check runs every three seconds while hidden.
- `HiddenItemsViews.swift`: a 30-point row above the existing details view, horizontal scrolling, hover feedback, internal drag reordering/insertion line, restore context menu, and a persistent management panel that stays open during native placement.
- `MenuBarOrganizerProbe.swift` and `main.swift`: an opt-in `--organizer-probe` diagnostic creating only disposable test status items. It checks for foreign items before exercising the separator and removes its own items afterward.
- `AppDelegate.swift`: wrapper integration, resizing, on-open discovery, menu dismissal before native activation, and restoration on termination. Existing tab coordinates and content sizes are unchanged.
- `MenuBarOrganizerTests.swift`: persistence/order, protected item rejection, no automatic hide after relaunch, refusal without verified placement, Restore All, and wrapper sizing/rendering.
- `MenuBarControlProtocol`: bounded request/response models and a tested protected-owner allow-list policy.
- `MenuBarHelperClient.swift`: isolated process, asynchronous pipe I/O, heartbeat, timeout, stale-reply cancellation, shutdown, and containment of immediate helper exits.
- `ThermoBarMenuHelper`: runtime bridge, parent lease, app/display safety recovery, and read-only `--probe`. `--organizer-diagnostics PATH` writes real-app AX visibility; `--organizer-self-test PATH` attempts hiding already selected apps, force-kills the child, and records restoration. Both diagnostics are opt-in.

## Hiding, restoration, and activation

On older macOS, hiding uses a ThermoBar-owned divider whose public `length` can push items leftward. On macOS 27, the process-scoped private assertion described above replaces that mechanism. Source applications retain ownership and are never quit or modified.

The older divider fallback requires every left-side status window to be selected/supported, ThermoBar to its right, and one display. Unknown windows/metadata prevent hiding. The macOS 27 verifier uses AX positions instead of obsolete per-item windows; display changes always reveal originals.

**Reveal** releases the helper assertion (or shrinks the legacy divider). **Restore All** also clears saved choices. Per-item **Restore to Menu Bar** reveals the group and removes that owner from the macOS 27 selection; the legacy fallback still requires moving the original right of the divider. Automatic reverse dragging is not implemented.

Clicking a representation reveals the group first, then rediscovers the original AX element by identity and attempts the original `AXPress` action. **Open Original Context Menu** attempts `AXShowMenu` only if advertised. If a custom item does not expose that action, its real icon remains revealed for direct interaction. No menu is reconstructed and no application main window is launched as a substitute.

The icon in the collection is the owning app's icon, with a full item tooltip. Exact status-item pixel capture would require additional screen-capture handling/permissions and is not included.

## Permissions and recovery

- Accessibility is checked without prompting; only **Enable Accessibility** requests it and opens the matching macOS settings page.
- Denial leaves hardware monitoring functional. Unsupported items cannot be selected.
- Input Monitoring and Screen Recording are not requested.
- A permission change, display/Space change, app launch/termination, sleep, or wake reveals the section. No automatic rehiding occurs.
- Selection and user-defined representation order persist. Hidden state deliberately does not persist: launch starts revealed for verification. App termination removes the divider; a process crash causes macOS to remove the owner's status items rather than permanently altering other apps.
- Identifier-less items use owner bundle plus AX child slot. This identity can change when an app recreates/reorders its items. Automatic hiding on relaunch is therefore forbidden. Missing items remain labelled unavailable and can be restored/removed from the saved collection.

## Runtime evidence and remaining limits

On this host (**macOS 27.0.1**), the packaged helper's read-only probe confirmed the framework, classes, and required selectors are available, and the app passed deep/strict signature verification. **83 automated tests passed**, including protected/system-owner rejection, wire format, missing helper, and immediate child-process failure containment. A real idle-helper lease test exited cleanly after **8.2 seconds** without heartbeats; no hiding request or assertion was activated in that test. The GUI-launched diagnostics and end-to-end check reported **Accessibility false** and correctly refused to hide anything. The user chose to enable Accessibility later. Real disappearance and active-assertion crash restoration therefore remain pending; no success claim is made.

### Permission refresh and IPC correction (October 26)

The macOS 27 permission page is **Privacy & Security → Device Control and Data Access**. Its ThermoBar switch was on, but targeted TCC logs showed `Failed to match existing code requirement`: the entry retained an older ad-hoc build's code hash. Removing/re-adding only ThermoBar through System Settings, with the user completing Touch ID, restored a positive trust check and real discovery of ChatGPT, TheBoringNotch, WeChat, and system extras.

The subsequent live test exposed an IPC bug: `FileHandle.read(upToCount: 4096)` waited for the requested pipe buffer or EOF. A three-byte reproduction blocked until the writer closed. Both helper and parent now use `availableData`; cancellation no longer explicitly closes a reader underneath an in-flight callback. A real-helper regression test confirms a small protected-owner request is rejected immediately while stdin remains open. **84 tests pass.** A standalone corrected-helper check returned `applied`, then `revealed` after termination; this validates the activation/release handshake, not the visible-icon or active-crash acceptance checks. The self-test also ignores its own application-launch notification to avoid cancelling its hide operation during startup.

The corrected packaged build needs its refreshed code hash authorized before repeating visual disappearance and active-helper crash checks. Its UI uses **Enable Access / Permission Settings** to avoid directing macOS 27 users to a nonexistent Accessibility category. Direct drag transfer remains unimplemented.

The verifier is conservative about notch/overflow, fullscreen/auto-hide, unavailable AX items, and unknown geometry. Such layouts can be refused. Legacy multi-display hiding is disabled; the macOS 27 helper uses a global app allow-list and releases on display changes, but interactive multi-display acceptance is unverified.

| Acceptance area | Evidence / status |
| --- | --- |
| Build and existing monitoring | Compiles; automated suite passed before packaging |
| Selection/order persistence and restore state | Automated tests |
| Existing tabs / resizable Sound and Fans | Existing tests plus wrapper sizing test |
| Management panel appearance | Rendered and inspected at actual size |
| Real external drag into dropdown | **Not implemented or live-tested**; fallback uses native horizontal Command-drag |
| Native separator hide/restore | Disposable-item probe run; hiding **not confirmed on this host** |
| Third-party discovery / native menu activation | **Needs Accessibility grant and manual testing** |
| Successful original-icon removal and source app continuing | **Not verified; no success claim** |
| Reordering inside collection | Internal-only drag implementation plus order persistence tests; interactive gesture needs manual check |
| Automatic individual native relocation | **Not implemented**; reveal and native placement required |

## Manual checks

1. Open ThermoBar → **+ Manage** → **Enable Accessibility**. Enable ThermoBar in Privacy & Security → Accessibility, then press **Refresh**. No Screen Recording permission should be requested.
2. Confirm the list contains real extras, identifies multiple independent items, and protects Apple/system entries. Denial or revocation must leave monitoring usable.
3. Select one nonessential third-party app. On macOS 27 use **Hide Selected**. On older systems use Prepare and horizontal Command-drag left of `|`, then Verify & Hide. Never drag outside the real menu bar.
4. Count the original visible icons and confirm the source app still runs. If an original remains, the operation must not report success; it must release/reveal. Verify unselected/system icons and Notification Center still work.
5. Click the selected representation. Confirm its real item is revealed and, where AX supports it, its original menu opens. For custom controls, click the revealed original icon. Test the original context menu separately.
6. Reorder two representations horizontally and restart ThermoBar. Verify order persists and launch starts revealed. Use an item's **Restore to Menu Bar**, move its original right of `|`, then verify the remaining selection. Use **Restore All** and confirm no separator remains.
7. Test permission revocation, sleep/wake, app quit/relaunch, display changes, notch/overflow, fullscreen, and auto-hide. Unsupported layouts must fail safely rather than displaying a false managed state.

Until steps 3–7 succeed on the user's Mac, this should be treated as an experimental compatibility fallback, **not a finished direct-drag menu bar manager**.
