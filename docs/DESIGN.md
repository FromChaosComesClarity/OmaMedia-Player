# Design notes

What is worth knowing about this player that is not obvious from the code.
OmaDVD-Player's [docs/DESIGN.md](https://github.com/FromChaosComesClarity/OmaDVD-Player/blob/main/docs/DESIGN.md)
holds the findings the two share — the 9/8 aspect correction, the measured safe
area, the burn-in reasoning, the AppImage bundling split. This file covers what
is different because this one plays **files**.

## 1. Why it is a separate program

A Video DVD is not a file. Playing one properly means CSS decryption, a title
table, editions, and an interface built around "which title is the movie" — all
of which OmaDVD-Player already does. Folding that in would double this player's
size to serve one disc type, and folding *this* into OmaDVD would put a file
browser in front of a program whose whole job starts with a disc already in the
drive.

So: when the browser finds a mounted disc with a `VIDEO_TS` directory **and**
OmaDVD-Player is installed, it offers the disc as a handover and exits into it.
Where OmaDVD is absent the VOB files underneath stay browsable like any other
media, so nothing is a dead end.

## 2. Finding things to play

One `lsblk -P` call answers "what is plugged in", needs no privileges (it reads
the udev database), and survives the mount paths people actually have:

```
NAME="sr0" RM="1" TYPE="rom" LABEL="MADLAX 14-26" MOUNTPOINT="/run/media/jose/MADLAX 14-26"
```

**⚠️ Use `-P` (key="value") and not columns.** Labels and mount points contain
spaces — that one has two — and a positional parse turns a real disc into
nonsense. `TYPE="rom"` is the optical drive; `RM="1"` is anything hot-plugged.

Directory listings come from `mp.utils.readdir`, which is built into mpv, so
browsing needs no subprocess at all. Files are filtered to a media extension
list: a folder of episodes should not show its `.sfv`, `.nfo` and cover art.

## 3. Subtitles: the opposite default from OmaDVD

`sub-auto=fuzzy`. A file very often has a `.srt` beside it, and finding it is
the entire point. OmaDVD switches this *off* because a DVD's subtitles are
inside the disc and a stray file in the mount would be noise.

**⚠️ Matroska tags languages with ISO 639-2 (`por`), containers and DVDs with
639-1 (`pt`).** Looking up only the two-letter prefix turns `por` into `PO`,
misses, and shows the viewer `POR`. The language table carries both spellings.

Subtitles also sit at `sub-pos=92` rather than the default 100: the bottom of
the raster is the part this tube eats.

## 4. Resume: mpv's own, for once

OmaDVD keeps a bespoke resume store keyed on the disc's serial number, because
every DVD presents the identical filename — `dvdnav://` — and mpv's watch-later
cannot tell them apart. A file has a stable path, so watch-later is simply
correct here, and one line of config beats a hundred of Lua.

## 5. Scaling actually costs something here

OmaDVD decodes 720×480 MPEG-2 and lands it 1:1 on a 720×480 framebuffer: the
scaler is a no-op and the settings barely matter. This player downscales 1080p
to 480 lines — a 2.25× reduction on an Intel HD 5000 with no VAAPI driver —
which is the one thing in either program that can fail to be real-time. Cheap
kernels and `correct-downscaling=no` are a deliberate trade, not an oversight.

## 6. Small things that bit

- **`audio-display=attachment` is not a value.** mpv accepts `no`,
  `embedded-first` and `external-first`, and rejects the whole line rather than
  ignoring it — so a typo here costs every setting after it in the file.
- **Blanking triggers on "no keypress", not "paused".** A browser is a static
  bright image that can sit there for days, and it is where this player spends
  most of its life.
- **Declare forward references at the top.** A local referenced before it is
  declared compiles to an `_ENV` global lookup — nil at runtime, and `luac -p`
  says nothing. `luac -p -l | grep '_ENV "'` lists every accidental global; if
  anything but the standard library shows up there, it is a bug.
- The script publishes what it is showing to `user-data/omaplay`, readable over
  mpv's IPC socket. mpv cannot screenshot with no file loaded — exactly the
  browser's state — so this is the only way to check that screen, and it makes
  the player scriptable as a side effect.
