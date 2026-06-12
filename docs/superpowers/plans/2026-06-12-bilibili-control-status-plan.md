# Bilibili Control Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CoolCast behave closer to the official Bilibili TV receiver for phone-side status display and controls, while preserving the already-working 4K casting path.

**Architecture:** Treat the Bilibili Nirvana 9958 long-link protocol as the control surface. Each experiment changes exactly one protocol variable, is installed on the Pad, then is verified with phone and Pad logcat before any next change.

**Tech Stack:** Flutter/Dart, Android ADB/logcat, Bilibili Nirvana native frames, existing `lib/main.dart` receiver code, `test/widget_test.dart`.

---

## Current Evidence

| Area | Confirmed |
|---|---|
| 4K playback | Working through NVA `Command=Play`, `/x/tv/playurl` fallback to `/x/player/playurl`, returned `quality=120`, `format=hdflv2`. |
| UPOS playback | Works with BiliDroid user-agent and Bilibili referer headers. |
| Duration experiment | CoolCast returned `duration=691733`, `durationMs=691733`, `timelength=691733` in `GetTvInfo`. |
| Phone result | Phone still logged `onSendReqFailed GetTvInfo ... -31001`, so fields alone are not enough. |
| Known regression | Applying NVA `Stop/Pause/Seek` side effects broke the main casting flow. Do not add command side effects until response ACK format is accepted. |
| Current suspicion | Phone may require response frame attributes, response timing, or connection lifecycle semantics beyond a JSON body. |

## Boundaries

| Rule | Reason |
|---|---|
| Preserve 4K casting after every task. | This is the main product goal and known-good path. |
| One protocol variable per install. | Avoid mixing root causes. |
| Do not apply `Pause`, `Seek`, or `Stop` side effects until ACK acceptance is proven. | Prior side-effect experiment broke casting. |
| Stop after any regression. | Revert the last experiment before continuing. |
| Use logs as pass/fail evidence. | Phone UI alone is ambiguous. |

## Files

| File | Responsibility |
|---|---|
| `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart` | Bilibili NVA parsing, response framing, status body, playback state. |
| `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart` | Protocol frame tests and status JSON tests. |
| `/Users/dengpeng/Documents/Coding/CoolCast/docs/bilibili-4k-cast-notes.md` | Record confirmed protocol findings after successful experiments. |

## Verification Commands

| Purpose | Command |
|---|---|
| Unit tests | `flutter test` |
| Static analysis | `flutter analyze` |
| Build APK | `flutter build apk --debug` |
| Install Pad | `/Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 8916aa45 install -r build/app/outputs/flutter-apk/app-debug.apk` |
| Start app | `/Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 8916aa45 shell monkey -p com.dengpeng.coolcast 1` |
| Clear logs | `/Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 8916aa45 logcat -c && /Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 10AE6U160X004M9 logcat -c` |
| Pad capture | `/Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 8916aa45 logcat -d -v time \| rg -i "CoolCast\|Nirvana#\|Command=GetTvInfo\|Command=GetVolume\|Command=Play\|frame response\|timelength\|durationMs\|quality\|playurl" --max-count 320` |
| Phone capture | `/Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 10AE6U160X004M9 logcat -d -v time \| rg -i "onSendReqFailed\|DefaultLinkDevice\|长链状态\|GetTvInfo\|GetVolume\|Nirvana\|duration\|timelength\|quality" --max-count 260` |

---

## Task 0: Baseline Lock

**Hypothesis:** Current tree must first be brought back to a known, documented baseline before new experiments.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 0.1 | Inspect current diff for unfinished status experiments. | Only intended baseline or one current experiment is present. |
| 0.2 | Ensure no NVA `Pause/Seek/Stop` side effects are active. | `Pause/Seek/Stop` responses do not call `_pause`, `_seekTo`, or `_returnToHome`. |
| 0.3 | Run `flutter test` and `flutter analyze`. | Both pass. |
| 0.4 | Install APK, clear logs, cast to `CoolCast 高清`. | Pad receives `Command=Play`, gets `quality=120`, and plays. |
| 0.5 | Capture phone logs. | If `onSendReqFailed Play` exists but video still plays, record it as baseline noise; if video fails, stop and revert last change. |

**Pass condition:** 4K playback works.

**Fail action:** Restore the last known working NVA response path: empty Play ACK, `GetTvInfo={"tvVipInfo":-1,"tvMid":null}`, `GetVolume={"volume":50}`.

---

## Task 1: Response Frame Attribute Experiment

**Hypothesis:** Phone marks `GetTvInfo/GetVolume` failed because response frames have empty attributes; official receiver may echo `Command`.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 1.1 | Add a test for a response frame to `GetTvInfo` that echoes `Command=GetTvInfo` in response attributes. | Test initially fails. |
| 1.2 | Change `_nirvanaFrameResponse` to include `{'Command': command}` only for NVA responses. | Test passes. |
| 1.3 | Keep body unchanged from baseline. | No duration fields yet. |
| 1.4 | Run tests/analyze/build/install/clear logs. | Clean install. |
| 1.5 | Cast once. | 4K still plays. |
| 1.6 | Inspect phone logs. | If `GetTvInfo/GetVolume -31001` disappears or changes, response attributes matter. |

**Pass condition:** Phone no longer reports `GetTvInfo/GetVolume -31001`, or log behavior changes while playback remains working.

**Fail action:** Revert response attributes and move to Task 2.

---

## Task 2: Response Timing Experiment

**Hypothesis:** Waiting for playurl before responding to `GetTvInfo` makes the phone time out; `GetTvInfo` must respond immediately.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 2.1 | Remove any wait on `_pendingBiliPlayUrl` from `GetTvInfo`. | Response is synchronous/immediate. |
| 2.2 | Return baseline body plus `duration=0`, `durationMs=0`, `timelength=0`. | Body shape includes fields without blocking. |
| 2.3 | Run tests/analyze/build/install/clear logs. | Clean install. |
| 2.4 | Cast once. | 4K still plays. |
| 2.5 | Inspect phone logs. | If `GetTvInfo -31001` disappears, timeout was the cause. |

**Pass condition:** Phone accepts `GetTvInfo` or stops reporting `-31001`.

**Fail action:** Revert timing experiment and move to Task 3.

---

## Task 3: Post-Play Status Refresh Experiment

**Hypothesis:** Initial `GetTvInfo` can be minimal, but phone needs a later accepted status update after playurl is ready.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 3.1 | Store current Bilibili status after playurl: `aid`, `cid`, `quality`, `timelength`, `accept_quality`. | No control side effects. |
| 3.2 | If phone sends another `GetTvInfo` after play starts, return status with real `timelength`. | Later response has `691733` style duration. |
| 3.3 | Do not delay the first `GetTvInfo`. | No startup timeout. |
| 3.4 | Run tests/analyze/build/install/clear logs. | Clean install. |
| 3.5 | Cast once, wait 10 seconds, open phone control panel if needed. | Look for additional `GetTvInfo`. |
| 3.6 | Inspect Pad logs. | Determine whether phone ever asks again after playurl is ready. |

**Pass condition:** Phone requests status again and accepts/display duration.

**Fail action:** If no second `GetTvInfo` occurs, do not keep adding body fields; move to Task 4.

---

## Task 4: Response Connection Lifecycle Experiment

**Hypothesis:** Phone reports `-31001` because CoolCast closes or half-closes the 9958 socket differently from official receiver.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 4.1 | Log every socket EOF/destroy with sequence and last command. | More precise lifecycle evidence. |
| 4.2 | Experiment A: keep socket alive after native frame response for 5 seconds. | Playback still works. |
| 4.3 | Verify phone logs. | If `-31001` changes, lifecycle matters. |
| 4.4 | If A fails, revert and experiment B: close immediately after response flush. | Compare phone behavior. |
| 4.5 | Keep only the lifecycle behavior that improves phone acceptance. | No speculative retention. |

**Pass condition:** One lifecycle mode removes or changes `-31001`.

**Fail action:** Revert lifecycle change and move to official comparison.

---

## Task 5: Official Receiver Comparison

**Hypothesis:** The missing piece is a specific official response body or response attribute not inferable from current logs.

**Files:**
- Read-only reference: `/Users/dengpeng/Downloads/iBiliTV-master.apk`
- Optional decompile output outside tracked source, e.g. `/tmp/coolcast-jadx/`
- Modify only after evidence: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`

| Step | Action | Expected |
|---|---|---|
| 5.1 | Use `jadx` to search official receiver code for `GetTvInfo`, `GetVolume`, `timelength`, `duration`, `Nirvana`, `Command`. | Locate candidate response model or native bridge. |
| 5.2 | Record exact class/method names and field names in notes. | No implementation yet. |
| 5.3 | Implement only the smallest matching field/attribute difference. | One variable changed. |
| 5.4 | Run tests/analyze/build/install/clear logs. | Clean install. |
| 5.5 | Cast once and inspect phone logs. | Determine if official field/attribute fixes acceptance. |

**Pass condition:** Phone accepts status request or UI begins showing duration.

**Fail action:** Revert and try the next official difference one at a time.

---

## Task 6: Control Commands After ACK Acceptance

**Hypothesis:** Controls should only be implemented after phone accepts status/control ACKs.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 6.1 | Add tests for parsing NVA `Pause`, `Resume/Play`, `Seek`, `Stop` bodies. | Tests fail before implementation. |
| 6.2 | Implement ACK-only responses first, no side effects. | Phone no longer reports command failure. |
| 6.3 | Add one side effect at a time, starting with `Pause`. | Pad pauses; phone does not reconnect-loop. |
| 6.4 | Add `Resume/Play`. | Pad resumes. |
| 6.5 | Add `Seek`. | Pad seeks; phone progress remains coherent. |
| 6.6 | Add `Stop` last. | Stop returns home without breaking future casts. |

**Pass condition:** Each command works on Pad and phone does not log `onSendReqFailed`.

**Fail action:** Revert only the last command side effect.

---

## Task 7: Quality Switching

**Hypothesis:** Quality switch depends on accepted status/control protocol, so it must come after Tasks 1-6.

**Files:**
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/lib/main.dart`
- Modify: `/Users/dengpeng/Documents/Coding/CoolCast/test/widget_test.dart`

| Step | Action | Expected |
|---|---|---|
| 7.1 | Capture phone action when tapping quality after status works. | Identify command name, likely `SetQuality` or another NVA command. |
| 7.2 | Add parser test for that command. | Test fails before implementation. |
| 7.3 | Fetch playurl using requested qn and existing `access_key`. | URL returned for requested quality. |
| 7.4 | Swap player URL without resetting cast session. | Pad switches quality. |
| 7.5 | Return updated status with new qn. | Phone UI reflects selected quality. |

**Pass condition:** Phone quality menu opens and selecting a quality changes Pad playback.

**Fail action:** Keep 4K default path and document unsupported quality command details.

---

## Execution Log

| Date | Task | Result | Evidence |
|---|---|---|---|
| 2026-06-12 | Plan written | Pending execution | This file. |
| 2026-06-12 | Task 0 baseline | Passed | Mi10 receiver received `Command=Play`; `/x/tv/playurl` returned `code=-400`; fallback `/x/player/playurl` returned `quality=120`, `timelength=2665726`; video played. Baseline phone logs still later report `Play/GetTvInfo/GetVolume -31001`. |
| 2026-06-12 | Task 1 response attributes | Failed, reverted | Response frames echoed `Command=Play/GetTvInfo/GetVolume`, but Vivo still later logged `onSendReqFailed Play/GetTvInfo/GetVolume ... -31001`; echoing response attributes is not sufficient. |
| 2026-06-12 | Task 2 immediate zero duration | Failed, reverted | Initial `GetTvInfo` returned `duration=0`, `durationMs=0`, `timelength=0`; playback still reached `quality=120`, but Vivo still later logged `Play/GetTvInfo/GetVolume -31001`; zero duration fields are not sufficient. |
| 2026-06-12 | Task 3 post-play status cache | Evidence gathered | Initial `GetTvInfo` stayed baseline; playurl success cached `quality=120`, `timelength=2665726`, `acceptQuality=[120,112,80,64,32,16]`; no second `GetTvInfo` was observed after cache, so phone does not appear to poll status again in this flow. |
| 2026-06-12 | Task 4-A 5s keepalive | Failed | Mi10 kept write side open for 5 seconds after ACK and playback still worked, but Vivo still later logged `onSendReqFailed Play/GetTvInfo/GetVolume ... -31001` at `09:55:27`; socket keepalive delay is not sufficient. |
| 2026-06-12 | Task 4-B immediate close | Failed | Mi10 responded to `Play/GetTvInfo/GetVolume`, fetched fallback playurl with `quality=112`, and destroyed socket immediately after EOF; Vivo still later logged `onSendReqFailed Play/GetTvInfo/GetVolume ... -31001` at `09:58:52`; immediate close is not sufficient. |

## Stop Conditions

| Condition | Action |
|---|---|
| 4K casting fails | Revert last experiment immediately. |
| Phone cannot discover `CoolCast 高清` | Stop protocol work and diagnose discovery. |
| Pad playback fails with HTTP/decoder error unrelated to NVA | Fix playback first, not control UI. |
| Three experiments fail with no signal change | Stop and decompile/compare official receiver before more guesses. |
