# media-payload-restore

Losslessly restore **second-hand obfuscated H.264/AAC media** into standard mp4 — no re-encoding.

> For media you lawfully own or have lawful access to (e.g. your own purchased course
> backups) whose **payloads were rewritten by the publisher**. The bundled player can
> play it; every standard toolchain either refuses or decodes garbage.
>
> **Read `DISCLAIMER.md` first. Personal backup / interoperability research only.**

[中文说明见 `README.md`](README.md)

---

## The problem

Some protected media, once decrypted, still isn't a standard bitstream:
**the container (MP4 / MPEG-TS) is perfectly well-formed, but the video and audio
payloads inside were rewritten.**

Typical symptoms with ffmpeg / VLC / NLEs:

```
[h264] non-existing PPS 0 referenced
[h264] decode_slice_header error
[h264] no frame!
[h264] Missing reference picture, default is 65
[h264] Reference 4 >= 4
[h264] corrupt decoded frame
[aac]  Prediction is not allowed in AAC-LC.
```

…yet the vendor's own custom decoder plays it fine.

## What this tool does

1. **Extracts the plaintext container** — the decryption key lives in the vendor player,
   so we proxy one of its FFmpeg modules and read the *already decrypted* stream out of it
   (see `docs/05-methodology.md`).
2. **Restores the rewritten payload** — bit-exact repair of H.264 slice headers and
   audio frame shifts, then remuxes to mp4 with `-c copy` (zero quality loss).

## Supported transforms

| # | Transform | Fix |
|---|---|---|
| 1 | Each slice payload prefixed with 1 byte `0x84` | strip it |
| 2 | Slice-header prefix: `slice_type` ↔ `pic_parameter_set_id` swapped | swap back |
| 3 | **One extra bit inserted after the prefix**, header padded to byte alignment | drop that bit (mind the byte-alignment special case) |
| 4 | Audio: a 17-byte marker every 256 frames; the next frame shifted by 1 bit | drop marker + shift right by 1 |

Case 3 is the crux. If the original header was already byte-aligned (`X % 8 == 0`),
that inserted bit drags along **7 extra padding bits** — dropping only one bit shifts
the CABAC start by a byte. That explains a puzzling **12.5 % (= 1/8)** error rate.
Details in `docs/02-avc-slice-restore.md`.

## Quick start (Windows)

```powershell
# 0) build the proxy DLL once
cd src\dll-proxy
python gen_proxy.py
gcc -m32 -O2 -shared -o ..\..\build\avformat-58.dll proxy.c ..\..\build\gen.c ..\..\build\gen.S ..\..\build\gen.def
cd ..\..

# 1) one file
.\scripts\extract-stream.ps1 -Input "D:\videos\lesson01.sz" -PlayerDir "D:\player"

# 2) whole tree (already-done files are skipped -> resumable)
.\scripts\restore-batch.ps1 -Input "D:\videos" -PlayerDir "D:\player"

# 3) full-decode verification
.\scripts\verify.ps1 -MediaDir "D:\videos"
```

## Requirements

Windows · PowerShell 5.1+ · Python 3.8+ (stdlib only) · ffmpeg.exe in the repo root ·
mingw-w64 **32-bit** gcc (to build the proxy) · your own copy of the vendor player.

## Docs

| File | Content |
|---|---|
| `docs/01-background.md` | Background & approach |
| `docs/02-avc-slice-restore.md` | Core: slice-header bit insertion & the 1/8 alignment trap |
| `docs/03-container-and-remux.md` | Container detection, timestamps, lossless remux |
| `docs/04-audio-restore.md` | Audio frame shift & marker blocks |
| `docs/05-methodology.md` | Methodology: locating such transforms, and extracting the plaintext |

## License

MIT — see `LICENSE`. Read `DISCLAIMER.md` before use.
