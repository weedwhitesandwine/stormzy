# Stormzy

Live weather radar in the Omarchy bar, for the place you choose.

![Stormzy](preview.png)

Pick a city and Stormzy shows the last couple of hours of radar over it,
looping, on a map drawn in your theme's colours. Over Japan it uses the
Japan Meteorological Agency's five-minute nowcast, including the hour of
forecast JMA publishes; everywhere else it uses RainViewer's composite of
national radar networks. The place is always yours to choose: nothing is
ever guessed from your IP address, and there is no location tracking.

## Install

```sh
omarchy plugin add https://github.com/weedwhitesandwine/stormzy.git --enable
```

Click the bar icon, open settings with the gear (or `s`), and type a city:
`Tokyo`, `Osaka`, `London, UK`, `New York`, `Seattle`. A country on its own
lists its biggest cities. Recent places become one-click chips, so switching
between the cities you move between is quick.

## Using it

| Key | Action |
| --- | --- |
| Space | Play / pause the loop |
| `[` `]` | Step one frame |
| Home / End | Oldest frame / newest observation |
| `h` `j` `k` `l` or arrows | Pan |
| `+` `-` | Zoom |
| `0` | Back to the chosen place |
| `s` or `/` | Settings and place search |
| `f` | Show or hide forecast frames (JMA) |
| Esc | Close |

Drag the map to pan and scroll to zoom. The timeline under the map is one
tick per frame; forecast frames are outlined, observations are solid, and
clicking a tick selects it. The stamp beside it is the frame's observation
time in your local time zone; the header says how old the newest scan is.

The radar source follows the place: **Auto** picks JMA for a place in
Japan and RainViewer elsewhere. Either can be forced in settings. JMA's
legend is millimetres per hour; RainViewer's tiles use its own reflectivity
colour schemes, four of which can be chosen in settings.

## What it runs, reads and writes

The shell starts one helper, `stormzyd.py` (Python 3, standard library
only), under `setpriv --pdeathsig TERM` so it ends with the shell. It is the
only part of Stormzy that touches the network:

| Host | When | What |
| --- | --- | --- |
| `www.jma.go.jp` | JMA selected | The nowcast frame index (two small JSON files) and 256 px PNG tiles for the area on screen |
| `api.rainviewer.com` | RainViewer selected | The frame index (one small JSON file) |
| `tilecache.rainviewer.com` | RainViewer selected | 256 px PNG tiles for the area on screen |

Every request is HTTPS with a ten-second timeout, carries only a User-Agent
naming this plugin, and is read to a fixed ceiling (256 KB for an index,
1 MB for a tile) and refused above it. A redirect to any other host is
refused. The frame index is refreshed once a minute while the window is
open and every ten minutes while it is closed; the latter can be turned off
in settings, after which nothing is fetched until the window opens.

Files:

| Path | What |
| --- | --- |
| `~/.local/state/omarchy/stormzy/settings.json` | The chosen place, recent places, zoom, source, colour scheme |
| `~/.cache/stormzy/tiles/` | Downloaded tiles, pruned to the frames the current index names and capped at 160 MB |

Nothing else on the machine is written. The window is opened from the bar
icon; `omarchy-shell shell toggle io.github.weedwhitesandwine.stormzy`
does the same from a script.

The basemap (coastlines, borders, state lines, lakes and city labels) is
Natural Earth, bundled under `data/`, so the map itself never leaves the
machine. The place search runs over a bundled GeoNames table of every town
above 5,000 people. `tools/build-data.py` regenerates those files from
their sources and is never run by the plugin.

## Update

```sh
omarchy plugin update io.github.weedwhitesandwine.stormzy
omarchy restart shell
```

## Remove

```sh
omarchy plugin remove io.github.weedwhitesandwine.stormzy
rm -rf ~/.cache/stormzy ~/.local/state/omarchy/stormzy
```

## Data and licence

Radar: [Japan Meteorological Agency](https://www.jma.go.jp/) high-resolution
precipitation nowcast and [RainViewer](https://www.rainviewer.com/).
Basemap: [Natural Earth](https://www.naturalearthdata.com/), public domain.
Places: [GeoNames](https://www.geonames.org/),
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Code: MIT, see [LICENSE](LICENSE).

Built with Claude Code.
