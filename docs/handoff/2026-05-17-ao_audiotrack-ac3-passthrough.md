# Handoff — ao_audiotrack.c: ENCODING_AC3 / ENCODING_E_AC3 passthrough

**Date:** 2026-05-17
**Branch:** `feature/ac3-passthrough` on `https://github.com/logo000/mpv-android`
**Workspace:** `/home/htpc/projekte/mpv/mpv-android` (clone of the fork)
**Goal:** Real AC-3 / E-AC-3 bitstream passthrough on Sony Bravia / Android TV devices that do **not** advertise `ENCODING_IEC61937`.
**Owner downstream consumer:** IrisHD at `/home/htpc/projekte/IrisHD` (uses `is.xyz.mpv` package via `io.github.abdallahmehiz:mpv-android-lib`). Long-term plan is to switch ALL playback to mpv.

---

## TL;DR

`audio/out/ao_audiotrack.c` in `mpv-player/mpv` only knows how to open
Android's `AudioTrack` with `AudioFormat.ENCODING_IEC61937` (= 13) for
compressed passthrough. Sony Bravia HDMI sinks advertise
`AudioFormat.ENCODING_AC3` (= 5) and `ENCODING_E_AC3` (= 6) directly
in the `ACTION_HDMI_AUDIO_PLUG` broadcast's `EXTRA_ENCODINGS`, but
**not** IEC61937. Result: `AudioTrack.getState()` returns
`STATE_UNINITIALIZED`, mpv logs `Failed to create AudioTrack` and silently
falls back to decoded PCM. The AVR sees PCM 5.1 over HDMI ARC, which
ARC downmixes to 2.0 LPCM, and the user gets no Dolby Digital label.

ExoPlayer/Media3 handles this exact case correctly via
`DefaultAudioSink.Builder().setAudioCapabilities(...)` — it picks
`ENCODING_AC3` / `ENCODING_E_AC3` directly and writes raw AC-3 frames
(no IEC61937 burst framing). We need the same path in mpv.

The mpv-android maintainer acknowledged this gap in Issue #93 back in
2018 (https://github.com/mpv-android/mpv-android/issues/93). It's still
unimplemented as of mid-2026. PR #5703 ("Consuming raw audio from ao
drivers") that would have unblocked the design was closed without merge.

---

## Source-of-truth references

- **Affected file (in upstream submodule that buildscripts clones):**
  `audio/out/ao_audiotrack.c` — full snapshot in `/tmp/ao_audiotrack.c`
  for offline review (mpv master @ 2026-05-17).
- **Key lines:**
  - `186-204` — JNI field declarations (ENCODING_PCM_8BIT, _16BIT, _FLOAT, _IEC61937 only)
  - `294` — `format_builder.setEncoding(p->format)` — where the
    AudioTrack format is finalised; new encodings just need to flow
    through here.
  - `336` — `AudioFormat.MIN_BUFFER_SIZE(samplerate, channel_config, p->format)`
  - `395, 435, 479, 498, 513, 713, 763, 772` — every site that
    branches on `p->format == ENCODING_IEC61937` to special-case
    compressed audio handling (write-as-shorts, channel layout
    pin-to-stereo, etc.). Each one needs a parallel branch for
    `ENCODING_AC3` / `ENCODING_E_AC3`.
  - `660-674` — the **only** path where ao->format gets mapped to an
    Android encoding. This is where the new decision logic goes.

- **Reference implementations:**
  - **VLC's `audiotrack` AO**:
    https://code.videolan.org/videolan/vlc/-/blob/master/modules/audio_output/audiotrack.c
    Look for `ENCODING_AC3`, `ENCODING_E_AC3`, `passthrough` keywords.
    Specifically the `AOUT_FMT_LINEAR` vs spdif branching, and the
    `JNI_GET_AUDIO_ENCODING_AC3` / `JNI_GET_AUDIO_ENCODING_E_AC3`
    field lookup.
  - **Media3's `DefaultAudioSink`**:
    https://github.com/androidx/media — class
    `androidx.media3.exoplayer.audio.DefaultAudioSink` and
    `androidx.media3.exoplayer.audio.AudioCapabilities`. Of particular
    interest: how it inspects `EXTRA_ENCODINGS`, falls back from
    AC-3 to PCM cleanly, computes `getMinBufferSize` for raw
    compressed streams (it uses a per-codec heuristic: 250 ms of
    bytes at the codec's bitrate, see
    `androidx.media3.exoplayer.audio.DefaultAudioSink#getDefaultBufferSize`).
  - **mpv-android Issue #93 thread**: the maintainer mentions
    "AudioTrack.write() works fine for AC-3 if the audio is
    constant bitrate". For Sky DE 098D iCAM, AC-3 384 kbps is
    constant-bitrate. So the write path itself is simple — just
    `AudioTrack.write(bytes)` of the raw AC-3 frames.

---

## What the patch must do

Concrete checklist. Implement in `patches/mpv/01-ao_audiotrack-encoding-ac3.patch`:

### 1. Add JNI field declarations

In the `AudioFormat_fields` struct (~line 186):
```c
jint ENCODING_AC3;
jint ENCODING_E_AC3;
```

In the JNI mapping table (~line 201):
```c
{"ENCODING_AC3",   "I", MP_JNI_STATIC_FIELD_AS_INT, OFFSET(ENCODING_AC3),   0},
{"ENCODING_E_AC3", "I", MP_JNI_STATIC_FIELD_AS_INT, OFFSET(ENCODING_E_AC3), 0},
```

The `0` in the last column = optional field (older Android API levels
won't have it; loader must not fail on missing). API 21 added `_AC3`,
API 21 also added `_E_AC3` — see
https://developer.android.com/reference/android/media/AudioFormat.

### 2. Update format selection at init time

In `init()` around line 660, replace the IEC61937-only branch:
```c
if (af_fmt_is_spdif(ao->format)) {
    p->format = AudioFormat.ENCODING_IEC61937;
    if (!p->format || !AudioTrack.writeShortV23) {
        MP_ERR(ao, "spdif passthrough not supported by API\n");
        return -1;
    }
}
```

with:
```c
if (af_fmt_is_spdif(ao->format)) {
    int spdif_codec = af_format_to_spdif_codec(ao->format);
    /* Prefer direct AC-3 / E-AC-3 AudioTrack encoding when the device
     * (i.e. its HDMI sink as advertised via ACTION_HDMI_AUDIO_PLUG)
     * supports it. Bravia / many Android-TV devices implement the raw
     * AC-3 encodings but NOT ENCODING_IEC61937 — see comment on Issue
     * #93. Fall back to IEC61937 burst framing when raw encoding is
     * unavailable (desktop-style spdif scenario). */
    if (spdif_codec == AC3 && AudioFormat.ENCODING_AC3) {
        p->format = AudioFormat.ENCODING_AC3;
        MP_VERBOSE(ao, "using ENCODING_AC3 direct passthrough\n");
    } else if (spdif_codec == EAC3 && AudioFormat.ENCODING_E_AC3) {
        p->format = AudioFormat.ENCODING_E_AC3;
        MP_VERBOSE(ao, "using ENCODING_E_AC3 direct passthrough\n");
    } else if (AudioFormat.ENCODING_IEC61937 && AudioTrack.writeShortV23) {
        p->format = AudioFormat.ENCODING_IEC61937;
        MP_VERBOSE(ao, "falling back to ENCODING_IEC61937\n");
    } else {
        MP_ERR(ao, "spdif passthrough not supported by API "
                   "(spdif_codec=%d, no AC3/EAC3/IEC61937 encoding "
                   "available)\n", spdif_codec);
        return -1;
    }
}
```

The helper `af_format_to_spdif_codec()` doesn't exist yet — it's a
~10-line helper that maps `AF_FORMAT_S_AC3` → AC3, `AF_FORMAT_S_EAC3`
→ EAC3, etc. See `audio/format.h` / `audio/format.c` for the existing
`AF_FORMAT_S_*` constants and `af_fmt_to_str()` for an analogous
mapping pattern.

### 3. Channel layout for raw AC-3

In the channel-config block (~line 713), the IEC61937 path pins to
STEREO. For ENCODING_AC3 / ENCODING_E_AC3, we want the **actual**
channel layout of the source stream:
```c
if (p->format == AudioFormat.ENCODING_IEC61937) {
    p->channel_config = AudioFormat.CHANNEL_OUT_STEREO;
} else if (p->format == AudioFormat.ENCODING_AC3 ||
           p->format == AudioFormat.ENCODING_E_AC3) {
    /* Raw AC-3 frames carry their own channel mapping. The AudioTrack
     * needs the source channel layout, not stereo. Use the normal
     * layout_map[] lookup so 5.1 sources land on CHANNEL_OUT_5POINT1. */
    p->channel_config = layout_map[ao->channels.num];
    mp_assert(p->channel_config);
} else {
    /* existing PCM path */
}
```

### 4. Write path — raw bytes, not IEC61937 bursts

In the audio data write paths (around lines 395, 498, 763, 772), every
`p->format == ENCODING_IEC61937` branch currently calls
`AudioTrack.writeShortV23(...)` and prepares IEC61937 burst headers.
For ENCODING_AC3 / ENCODING_E_AC3, mpv must instead call the byte-write
variant (`AudioTrack.writeV21` / `writeV23` with `int` byte count) and
hand it the raw AC-3 frame bytes from `ao->buffer`.

Concrete: where the code currently does
```c
if (p->format == AudioFormat.ENCODING_IEC61937) {
    /* short[] write path with IEC61937 framing */
}
```
add an OR for the new encodings but **without** the IEC61937 burst
header preparation:
```c
if (p->format == AudioFormat.ENCODING_AC3 ||
    p->format == AudioFormat.ENCODING_E_AC3) {
    /* Raw codec frames. ao->buffer already contains decoder-output
     * bytes that are the unmodified AC-3 elementary stream from the
     * input demuxer. Just write them. No burst header. */
    ret = MP_JNI_CALL_INT(p->audiotrack, AudioTrack.write,
                          jbuffer, 0, write_len);
}
```

### 5. Buffer-size heuristic

`AudioTrack.getMinBufferSize(samplerate, channel_config, format)` may
return -1 for ENCODING_AC3 on some devices. ExoPlayer falls back to a
per-codec default: 250 ms of audio at the codec's bitrate. For 384 kbps
AC-3 that's `0.25 * 384000 / 8 = 12000 bytes`. For 5.1 E-AC-3 at 768
kbps that's `0.25 * 768000 / 8 = 24000 bytes`. Implement a small
fallback table when `getMinBufferSize` errors out:
```c
if (buffer_size <= 0) {
    if (p->format == AudioFormat.ENCODING_AC3)
        buffer_size = 12000;     // 250ms * 384kbps
    else if (p->format == AudioFormat.ENCODING_E_AC3)
        buffer_size = 24000;     // 250ms * 768kbps
    else
        goto error;
}
```

---

## Build / test loop

```bash
cd /home/htpc/projekte/mpv/mpv-android/buildscripts

# One-time: download all deps (~2 GB, includes mpv source clone)
./buildall.sh -n

# Apply our patches + build libmpv only (fast, ~3 min on a workstation)
cd scripts && ./mpv.sh build && cd ..

# Build the AAR for IrisHD consumption (needs Android SDK)
cd .. && ./gradlew :app:assembleRelease
```

The output AAR ends up in `app/build/outputs/aar/`. To consume from
IrisHD, two options:

1. **Maven Local** — publish locally, then bump the version in
   `IrisHD/gradle/libs.versions.toml`:
   ```bash
   ./gradlew :app:publishToMavenLocal
   # IrisHD: mpv-android-lib = "logo000-1"
   ```
2. **Direct AAR include** — `cp app-release.aar
   /home/htpc/projekte/IrisHD/app/libs/` and switch the gradle dep to
   `implementation(files("libs/mpv-android-lib-logo000.aar"))`.

### Verification on Bravia

After building+installing IrisHD with the patched libmpv, watch a Sky
DE channel and grep logcat:
```bash
ADB=/home/htpc/.codex/memories/android-tools/platform-tools/adb
$ADB -s 192.168.178.105:5555 logcat -d --pid=$($ADB -s 192.168.178.105:5555 shell pidof de.irishd.app) \
  | grep -E 'audio-spdif|ENCODING_AC3|using ENCODING|AO:'
```

Success criteria:
- mpv log: `using ENCODING_AC3 direct passthrough` (our new VERBOSE line)
- mpv log: `AO: [audiotrack]` with codec annotation rather than
  `48000Hz 5.1 6ch float`
- AVR display: shows "Dolby Digital" (DD5.1) instead of multi-channel
  PCM or DD+ 2.0
- No `AudioTrack.getState failed` errors
- No regression in sample-rate / channel detection

---

## Context the patch author needs

**Why mpv only ever did IEC61937:** mpv's internal AO architecture
delivers audio data as decoded PCM (`mp_audio_buffer`) or as
"spdif-wrapped" bursts (`AF_FORMAT_S_AC3` etc.). The IEC61937 path
treats the spdif-wrapped bytes as opaque shorts and lets AudioTrack
emit them via S/PDIF burst protocol — that's the desktop scenario
(receiver decodes the burst). On Android, the equivalent is
`ENCODING_IEC61937` which **wraps** the bytes again. ExoPlayer
took a different route — it asks ffmpeg for the **raw** AC-3 ES
frames (no spdif wrapping) and writes them directly with
`ENCODING_AC3`. mpv has no API for "give me raw AC-3 frames" yet —
PR #5703 was the attempt, never landed.

**Pragmatic workaround inside ao_audiotrack:** the spdif-wrapped data
mpv already produces contains the same AC-3 bytes plus IEC61937
preamble (`0xF872 0x4E1F` sync + Pa Pb Pc Pd header). ExoPlayer-style
ENCODING_AC3 wants the raw frames **without** the preamble. So in the
write path, the ENCODING_AC3 branch must either:

(a) Strip the IEC61937 preamble before writing (skip 8 bytes before
each AC-3 frame). Simple but requires understanding mpv's spdif
muxer layout.

(b) Bypass mpv's spdif muxer entirely and ask for raw bytes upstream.
This is what PR #5703 prototyped — too invasive for a downstream patch.

(c) Configure mpv's spdif muxer to NOT add the IEC61937 wrapper when
the target AO is going to do ENCODING_AC3 direct. Likely needs a
new internal flag plumbed through `audio/decode/ad_spdif.c`.

Option (a) is the smallest patch. Implement byte-skip logic in the
write callback only when format is ENCODING_AC3/E_AC3.

The IEC61937 burst layout for AC-3 (spec: IEC 61937-3):
```
offset 0..3:  Pa Pb (sync) = 0xF8 0x72 0x4E 0x1F
offset 4..5:  Pc (data type info) = 0x00 0x01 for AC-3
offset 6..7:  Pd (length in bits, big-endian)
offset 8..N:  raw AC-3 frame, byte-swapped (16-bit endianness flip)
              -- this is the byte-swap quirk of spdif transport
```
For ENCODING_AC3 writes we want bytes 8..N **un-byte-swapped**. So the
patch is: skip the 8-byte burst header AND unswap bytes back to native
order. ffmpeg's spdif demuxer in `libavformat/spdif.c` has the inverse
operation as reference.

---

## Constraints & gotchas

- **Don't break the existing IEC61937 path** — other Android TV devices
  (Shield, MiBox in certain modes, FireTV) do advertise IEC61937 and
  rely on it. The fallback order MUST be:
  1. ENCODING_AC3 / E_AC3 if input is AC-3/E-AC-3 AND device advertises
  2. ENCODING_IEC61937 if device advertises
  3. PCM (decoded) — current default

- **Android API levels:**
  - `ENCODING_AC3` added in API 21 (Lollipop) — already past mpv's min
  - `ENCODING_E_AC3` added in API 21
  - `ENCODING_IEC61937` added in API 24 (Nougat)
  - So AC-3 paths are AVAILABLE on older devices than IEC61937 is.

- **mpv-android-lib singleton history:** `abdallahmehiz/mpv-android`
  branch `library` has a "Make mpv support multiple instances"
  commit (Feb 2026). If we're publishing as `mpv-android-lib`, we
  should track the abdallahmehiz fork's `library` branch to preserve
  that capability — IrisHD relies on it. Alternative: apply our patch
  on top of the abdallahmehiz fork instead of the vanilla `mpv-android`.

- **Sky DE 098D iCAM cohort-trust integration:** completely independent.
  The TVHM-v5 cohort-trust fix (commit 96846ad) makes sure the AC-3
  bytes we feed into mpv are byte-correct. Without the cohort-trust
  fix you'd hit `expacc 127 is out-of-range` errors even with
  passthrough working — the AVR would also see the corruption.

- **HDMI ARC vs eARC:** Bravia's HDMI ARC port can carry compressed
  Dolby Digital but only stereo LPCM. eARC can carry compressed
  Dolby Atmos and 5.1 LPCM. If the user's AVR is connected via ARC
  only, this patch is the only way to get 5.1 sound to the AVR via
  the Bravia.

---

## Testing matrix

| Device | HDMI sink | Expected behaviour |
| --- | --- | --- |
| Sony Bravia VH2 (4K) | `encodings=[5, 6, ...]` no 13 | ENCODING_AC3 direct ✓ |
| Bravia ARC → AVR | Bravia advertises what AVR advertises | same as above |
| Shield TV Pro | typically `[13]` (IEC61937) | falls back to ENCODING_IEC61937 ✓ |
| MiBox 3 | varies | `[5]` AC-3 direct, no IEC61937 → ENCODING_AC3 ✓ |
| FireTV Cube | usually `[13]` | IEC61937 ✓ |
| Pixel phone HDMI | usually `[13]` | IEC61937 ✓ |
| Desktop Linux (S/PDIF) | n/a — ao_alsa path, untouched | unchanged |

Build the patched AAR and run all of the above. Output expected:
- 5.1 channels carried as the codec's native layout (not flat 6ch PCM
  downmix on ARC)
- AVR shows "Dolby Digital" or "Dolby Digital Plus"
- Sky DE channels (098D iCAM mode-4) play without `expacc` errors when
  combined with TVHM-v5's cohort-trust patch (separate, already deployed)

---

## Files to touch in this repo

```
mpv-android/
├── buildscripts/scripts/mpv.sh    # already patched — applies patches/mpv/*.patch
├── patches/
│   ├── README.md                  # already created
│   └── mpv/
│       └── 01-ao_audiotrack-encoding-ac3.patch   # ← create this
└── docs/handoff/2026-05-17-ao_audiotrack-ac3-passthrough.md   # this file
```

The patch file `01-ao_audiotrack-encoding-ac3.patch` is what you, the
next chat, will create. It's a unified diff (`git diff` output) against
`mpv-player/mpv` master at the SHA used by `buildscripts/include/depinfo.sh`
(check that file for the pinned ref).

---

## Verification of the upstream state before you start

```bash
gh api repos/mpv-player/mpv/commits/master --jq '.sha'
# whatever HEAD is when you run this

gh api repos/mpv-player/mpv/contents/audio/out/ao_audiotrack.c --jq '.content' \
  | base64 -d > /tmp/upstream-ao_audiotrack.c
wc -l /tmp/upstream-ao_audiotrack.c
# 856 lines as of 2026-05-17. Patch against this exact content.
```

Compare any working VLC AOAndroid reference:
```bash
curl -sL https://code.videolan.org/videolan/vlc/-/raw/master/modules/audio_output/audiotrack.c \
  > /tmp/vlc-audiotrack.c
grep -nE 'ENCODING_AC3|ENCODING_E_AC3|audio_format_is_passthrough' /tmp/vlc-audiotrack.c
# VLC's working passthrough code paths
```

---

## Acceptance criteria

The patch is complete when:

1. `./buildscripts/scripts/mpv.sh build` succeeds without warnings
2. Resulting `libmpv.so` strings show:
   ```
   strings libmpv.so | grep -E 'ENCODING_(AC3|E_AC3|IEC61937)'
   ```
   Output contains all three.
3. IrisHD bundled with the new AAR plays Sky DE Nature (channel id
   `nit-192e-11915-h-27500-dvbs2-118`) and:
   - logcat contains `using ENCODING_AC3 direct passthrough`
   - logcat does NOT contain `Failed to create AudioTrack`
   - AVR display shows "Dolby Digital"
4. Shield TV (if available for cross-test) plays the same channel via
   IEC61937 fallback without regression.
5. The patch round-trips through `git apply --check` then
   `git apply --reverse --check` (= idempotent + reversible).

---

## Done? Open a PR.

Once the patch is in place:
```bash
cd /home/htpc/projekte/mpv/mpv-android
git add patches/ buildscripts/scripts/mpv.sh docs/handoff/
git commit -m "ao_audiotrack: ENCODING_AC3/E_AC3 direct passthrough for Android TV"
git push origin feature/ac3-passthrough
gh pr create --base master --title 'ao_audiotrack: ENCODING_AC3/E_AC3 direct passthrough' \
  --body 'Bravia and many Android TV devices advertise raw AC-3 encodings on
HDMI but not IEC61937. mpv currently fails to open passthrough on those
devices and falls back to PCM, which the AVR then downmixes to 2.0
across ARC. This patch adds the direct ENCODING_AC3 / ENCODING_E_AC3
paths (modelled on VLC/ExoPlayer), with IEC61937 retained as fallback
for devices that prefer it.

Long-form rationale in `docs/handoff/2026-05-17-ao_audiotrack-ac3-passthrough.md`.'
```

Then consider proposing the same patch upstream to `mpv-player/mpv`
under the issue #93 thread so the fork can eventually retire.
