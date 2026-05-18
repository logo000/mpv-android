# mpv-android downstream patches

Patches in `mpv/` are applied to the upstream `mpv-player/mpv` source tree
after `buildscripts/include/download-deps.sh` clones it (into
`buildscripts/deps/mpv/` and checks out the SHA pinned by `$v_mpv` in
`buildscripts/include/depinfo.sh`) and before
`buildscripts/scripts/mpv.sh` runs `meson setup` + `ninja`.

**Pinned SHA:** `$v_mpv` in `depinfo.sh` controls the mpv checkout the
patches were generated against. Bump it in lockstep with any patch re-roll.

The application is automatic — `mpv.sh` walks every `*.patch` in
`/patches/mpv/` and runs `git apply --check` then `git apply`. The check
step is idempotent: a patch already applied (re-run with cached deps) is
detected and skipped via `git apply --reverse --check`.

## Adding a patch

1. Drop the file into `patches/mpv/NN-short-name.patch`. Numeric prefix
   controls apply order (lexicographic).
2. Test:
   ```
   cd buildscripts
   ./buildall.sh -n   # download deps
   cd scripts && ./mpv.sh build
   ```
3. Commit both the patch and the buildscript reference. The patch lives
   in this fork forever until/unless it's upstreamed.

## Active patches

| File | Purpose | Upstream status |
| --- | --- | --- |
| `mpv/01-ao_audiotrack-encoding-ac3.patch` | Add `ENCODING_AC3` / `ENCODING_E_AC3` direct-AudioTrack passthrough for Bravia/Android-TV devices that don't advertise `ENCODING_IEC61937`. See `docs/handoff/2026-05-17-ao_audiotrack-ac3-passthrough.md`. | not submitted yet — would supersede the IEC61937-only path in `audio/out/ao_audiotrack.c:660-674` |
