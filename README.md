# OmaMedia-Player

A media player for a CRT television.

Part of the [OmaCRT](https://github.com/FromChaosComesClarity/OmaCRT) family:
an Omarchy machine on a composite-fed tube at **720×480, genuinely interlaced
(480i)**, driven from the couch. It browses what you have — a disc in the
drive, a USB stick, your own folders — and plays it, with an interface built
for that screen rather than shrunk to fit it.

Sibling to
[OmaDVD-Player](https://github.com/FromChaosComesClarity/OmaDVD-Player), and
deliberately not the same program. That one knows about CSS keys, title tables
and disc structure; this one knows about files. Each does one job. A Video DVD
found here is handed over rather than reimplemented.

## What it does

- **Plays what you throw at it** — MKV, MP4, AVI, MOV, WebM, MPEG, TS, WMV,
  FLV, OGV and the rest, plus music files, through a bundled mpv.
- **Multiple audio tracks**, listed by their own titles and languages, switched
  live.
- **Subtitles**, embedded or a `.srt` sitting beside the file, with an Off row
  that is always first.
- **Picture controls** — aspect, deinterlacer, fill — the same three that
  matter on a tube.
- **Browses** the optical drive, any mounted USB volume, and `~/Videos`,
  `~/Music`, `~/Downloads` and `~/`. Folders first, media only, hidden files
  and stray `.srt`/`.nfo` left out.

```
  Afro Samurai                                              23:13
  ┌────────────────────────────────────────────────────────────┐
  │ ..                                                         │
  │ [TNNAC]_Afro_Samurai_01                             MKV    │
  │ [TNNAC]_Afro_Samurai_02                             MKV    │
  │ [TNNAC]_Afro_Samurai_03                             MKV    │
  └────────────────────────────────────────────────────────────┘
  Enter select    Esc back                                  2/6
```

Four arrows and two buttons drive all of it, in the browser and during playback
alike — so a keyboard on the arm of the sofa and a gamepad through OmaCRT's
input daemon work identically, with no modifier keys.

## The CRT parts that are not cosmetic

**Aspect.** A 720×480 framebuffer shown as 4:3 has non-square pixels — 8:9. mpv
assumes square pixels, so left alone it "corrects" 4:3 content to 640×480 and
pillarboxes it, and the tube stretches that back out 12.5% too wide. OmaMedia
overrides the display aspect with the true one × 9/8, so 4:3 lands 1:1 and 16:9
letterboxes correctly. The Picture menu can force either, for files that lie.

**Safe area** of 10% top, 6% bottom, 5% sides — measured on a real set, not the
5% broadcast standard, which this tube overscans straight past at the top.
Subtitles are lifted clear of it too.

**Stroke floor** of 4px (two scanlines): thinner detail is re-lit 30 times a
second instead of 60 and shimmers. Flat fills, no hairline outlines.

**Colour** — warm off-white rather than #FFF, which blooms; amber for
selection; no saturated red for text, because composite chroma bleeds worst on
red.

**Audio** downmixed to stereo, because composite carries stereo. Skip that and
a 5.1 track loses its centre channel, which is where the dialogue is.

**Burn-in.** The screen blanks after 4 minutes with no keypress — *no keypress*,
not *paused*, because a file browser left open overnight burns in exactly like
a paused frame, and the browser is where a player like this spends most of its
life.

**Scaling.** Unlike a DVD player, this downscales HD to 480 lines, which on a
Haswell iGPU is the one thing that can fail to be real-time. Cheap kernels with
`correct-downscaling=no` are a deliberate choice, not an oversight.

## Install

Drop the AppImage in `~/Applications` and OmaCRT's launcher will find it:

```sh
chmod +x OmaMedia-Player-x86_64.AppImage
mv OmaMedia-Player-x86_64.AppImage ~/Applications/OmaMedia-Player.AppImage
```

```sh
OmaMedia-Player.AppImage                    # open on the list of places
OmaMedia-Player.AppImage ~/Videos           # open the browser there
OmaMedia-Player.AppImage film.mkv           # just play it
OmaMedia-Player.AppImage -a en -s pt        # preferred languages
```

Needs FUSE 2 (`pacman -S fuse2`), or run with `--appimage-extract-and-run`.

## Keys

| Key | In the browser | While playing |
|-----|----------------|---------------|
| ↑ ↓ | move | previous / next chapter |
| ← → | back / open | seek ∓10s |
| Enter | open / play | menu |
| Esc | up a level | menu |
| Space | play | play / pause |
| `m` | — | menu |
| `a` / `j` | — | cycle audio / subtitles |
| `d` | — | cycle deinterlacer |
| `z` / `Z` | — | nudge subtitle timing |
| `9` / `0` | volume | volume |
| `q` | quit | quit |

Resume is mpv's own watch-later, which is exactly right here: a file has a
stable path to key on.

## Gamepad

mpv has first-class SDL gamepad input, so this needs **no daemon** and works even
with OmaCRT's own input daemon disabled. Plug a pad in and it is recognised.

| Button | In a menu | While playing |
|---|---|---|
| D-pad / left stick ↑ ↓ | move | previous / next chapter |
| D-pad / left stick ← → | back / select | seek ∓10s |
| A | select | menu |
| B | back | menu |
| X | select | play / pause |
| Start, Menu | close | menu |
| L1 / R1 | — | previous / next chapter |
| L2 / R2 | — | seek ∓60s |

Every binding names its keyboard and gamepad keys in the same call, so the two
cannot drift apart.

## Build

```sh
packaging/build-appimage.sh
```

Needs `mpv` on the build machine; it and its codec stack get copied into the
bundle. `appimagetool` is fetched on first run and cached.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
