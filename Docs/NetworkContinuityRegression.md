# Network continuity regression

This change preserves the screen-lock fix introduced in 1.0.9 and separates
provider recovery, route quality, and initial connection setup. Probe exhaustion
keeps the provider alive; engine termination still uses the existing reconnect
policy. The user can explicitly disconnect even while the network is recovering.

## Manual acceptance

Use the designated isolated Mac for Network Extension validation. Install a
build containing this change; an already-running 1.0.8 does not acquire source
fixes. Confirm both the app and the active extension build numbers.

Run each scenario in TUN and transparent-proxy mode:

1. Start a download or SSH session. Lock and unlock the screen several times,
   including a period with the display off but the computer awake. The original
   connection must remain alive, with no core reset, provider restart or new
   connection animation.
2. Actually sleep and wake the machine, and separately switch its physical
   uplink. The UI should say “Recovering network” during provider recovery,
   retain the session time, and offer Disconnect in both the window and menu.
   Physical sleep or a changed source address may invalidate existing sockets;
   this is distinct from screen-lock continuity.
3. Make the first probe endpoint unavailable while a fallback remains reachable.
   Recovery should finish without stopping the tunnel. If all probe endpoints
   are unavailable but rule-based traffic still works, other routes must remain
   usable. An unverified route remains a quality issue, not an automatic stop.
4. With an unavailable uplink, explicitly disconnect during recovery. No delayed
   host reconnect may override that action. Restore the uplink and reconnect.

## Automated checks

- `scripts/test_repository_ci.sh` and `scripts/test.sh`: ordinary repository,
  compile and unit gates; they do not load a real Network Extension.
- `Tests/RuntimeEnvironment/run.sh`: isolated workspace notification handling.
  This is not proof of real screen-lock delivery or a live data path.
- `scripts/test_lock_continuity_probe.py`: verifies that the persistent-connection
  helper fails on a closed connection instead of silently reconnecting.
- `scripts/test_vm_sleep_wake_recovery.sh`: despite its historical filename,
  tests **screen-lock notification continuity**, not actual system sleep. It
  requires an opted-in QA autoconnect build and Python 3 in the isolated VM.
  The HTTPS 204 endpoint must support keep-alive. One TCP connection must span
  lock and unlock, and the provider PID and network lifecycle must stay stable.
- `scripts/test_sleep_wake_recovery.sh`: freezes and resumes the VM, then uses
  the QA-only power-event bridge. Build with `AETHERROUTE_QA_AUTOMATION=1` and
  launch with `AETHERROUTE_QA_POWER_EVENTS=1`. This simulates power transitions;
  it does not prove that macOS delivers physical sleep notifications. Production
  builds do not include the bridge. Screen unlock never invokes it.
- `AETHERROUTE_UI_REVIEW_CASE_FILTER=recovering scripts/capture_ui_review.sh`:
  isolated English and Chinese recovery presentation snapshots.

## Risk and rollback

When no route works, an active tunnel may remain unusable until connectivity
returns or the user disconnects; this avoids discarding unrelated working routes
because one probe target fails. Multiple fallback probes add bounded network
requests during recovery. Receiving new bytes confirms some traffic works, not
that every rule or destination works.

There is no configuration migration. Revert the recovery change and rebuild to
roll it back; retain the separate 1.0.9 screen-lock fix. Install the previous
signed build only through the usual extension replacement workflow.
