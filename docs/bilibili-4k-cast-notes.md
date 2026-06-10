# Bilibili 4K Cast Notes

Date: 2026-06-10

## Goal

Make CoolCast receive Bilibili mobile projection like the official Bilibili TV receiver, including 4K playback when the source video and account allow it.

## Test Devices

| Role | Device | IP |
| --- | --- | --- |
| Receiver | Mi Pad 4, adb `8916aa45` | `192.168.1.114` |
| Sender | phone, adb `10AE6U160X004M9` | `192.168.1.142` |

`192.168.1.5` was observed in earlier captures but is a NAS, not the sender phone.

## Confirmed Protocol Path

| Step | Result |
| --- | --- |
| Discovery | Phone discovers `CoolCast MiPad4 114`. |
| UPnP metadata | Phone fetches `/bilibili/description.xml`, `/AVTransport/scpd.xml`, `/RenderingControl/scpd.xml`, and `/NirvanaControl/scpd.xml`. |
| Nirvana long link | Phone connects to receiver port `9958`; `SETUP` and `RESTORE` receive `200 OK`. |
| Play command | Receiver parses native NVA `Command=Play` frames with `aid`, `cid`, `accessKey`, `qn`, and projection metadata. |
| TV playurl | `/x/tv/playurl` consistently returns `code=-400` in current emulation. Do not keep randomly varying this endpoint without new evidence. |
| Public fallback | `/x/player/playurl` works with `bvid+cid` or `avid+cid`. |
| Anti-leech playback | UPOS playback needs Bilibili-style `User-Agent` and `Referer`; otherwise ExoPlayer gets HTTP `403`. |
| 4K | With `access_key`, `fnval=4048`, `fourk=1`, and `qn=120`, `/x/player/playurl` returned `quality=120`, `format=hdflv2`. The Pad player showed 4K. |

## Important Findings

1. Some Play bodies include a valid `bvid`; some include `bvid` as an empty string.
2. When `bvid` is empty, fallback must use `avid + cid`.
3. `access_key` alone did not raise the response above 720P.
4. `access_key + fnval=4048` exposed high-quality options including `120/112/80/64/32/16`.
5. Requesting `qn=120` returned `quality=120` for the tested 4K-capable video.
6. The phone Play body may still report `qn=80`; CoolCast now treats this as sender-side current quality, not as the receiver cap, and requests 4K when login credentials are available.

## Implemented Behavior

| Area | Behavior |
| --- | --- |
| Play parsing | Parses Bilibili NVA Play bodies and extracts `aid`, `cid`, `accessKey`, `qn`, `userDesireQn`, `mobileVersion`, and nested `bvid`. |
| Fallback URL | Builds `/x/player/playurl` with `bvid+cid` when available, otherwise `avid+cid`. |
| 4K request | Uses `qn=120`, `fnval=4048`, `fourk=1`, and `access_key` when login credentials are present and no explicit positive `userDesireQn` is supplied. |
| Playback headers | Supplies `User-Agent: Mozilla/5.0 BiliDroid` and Bilibili `Referer` to ExoPlayer via `VideoPlayerController.networkUrl`. |
| Tests | Widget tests cover Bilibili Play parsing, signed TV URL construction, public fallback URL construction, `bvid`-empty fallback, playback headers, and playurl JSON URL extraction. |

## Verified Commands

```bash
dart format lib/main.dart test/widget_test.dart
flutter test
flutter analyze
flutter build apk --debug
/Users/dengpeng/Library/Android/sdk/platform-tools/adb -s 8916aa45 install -r build/app/outputs/flutter-apk/app-debug.apk
```

Latest verification:

| Check | Result |
| --- | --- |
| `flutter test` | 31 tests passed |
| `flutter analyze` | No issues found |
| Debug APK build | Success |
| Real device test | Bilibili projection reached `quality=120`; player UI showed 4K |

## Useful Log Evidence

The successful 4K run included:

```text
B站 NVA Play ... aid=116577005475345 cid=38343344355 qn=80 contentType=0
B站 tv playurl response ... {"code":-400,"message":"请求错误","ttl":1}
B站 tv playurl failed, fallback to player playurl
B站 player playurl response ... "quality":120,"format":"hdflv2"
B站 playurl OK ...
ExoPlayer Init ...
```

## Known Gaps

| Gap | Next Debug Target |
| --- | --- |
| In-app quality switching may still differ from official TV receiver. | Capture phone logs while changing projection quality; look for new NVA `Command`, `SetQuality`, or status query frames. |
| Receiver status reporting is minimal. | Compare official TV receiver responses for `GetTvInfo`, progress, quality, and device capability fields. |
| `/x/tv/playurl` still returns `-400`. | Only revisit with stronger evidence from official receiver request parameters or decrypted app path. |

