#!/usr/bin/env python3
"""Stormzy's helper: the one process that touches the network or the disk.

Started by the shell (through `setpriv --pdeathsig TERM`, so it cannot outlive
it) and spoken to over stdin/stdout, one JSON object per line. It answers:

  {"op":"search","id":N,"q":"..."}             -> {"op":"search","id":N,"results":[...]}
  {"op":"frames","provider":P}                  -> {"op":"frames","provider":P,"frames":[...],"error":""}
  {"op":"tiles","req":N,"provider":P,"frame":F,
   "z":Z,"scheme":S,"tiles":[[x,y],...]}        -> {"op":"tile",...,"file":path|null} per tile,
                                                   then {"op":"tiles_done","req":N}
  {"op":"basemap","req":N,"zoom":Z,"bbox":[w,s,e,n]}
                                                -> {"op":"basemap","req":N,"lines":{...},"places":[...]}
  {"op":"cleanup"}                              -> prunes the tile cache

Network: only the hosts in PROVIDERS are ever contacted, over HTTPS, with a
ten-second timeout, and every body is read to a ceiling plus one byte and
refused above it. A redirect to any other host is refused. Nothing is sent
beyond the request itself and a User-Agent naming this plugin.

Disk: tiles land under $XDG_CACHE_HOME/stormzy (default ~/.cache/stormzy),
written to a random temporary name and renamed into place. The bundled data
under the plugin's data/ directory is read, never written.
"""
import gzip
import json
import stat
import os
import re
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from array import array
from concurrent.futures import ThreadPoolExecutor

VERSION = "0.1.0"
USER_AGENT = "stormzy/%s (Omarchy plugin; https://github.com/weedwhitesandwine/stormzy)" % VERSION

HERE = os.path.dirname(os.path.realpath(__file__))
DATA_DIR = os.path.join(HERE, "data")

MAX_LINE = 64 * 1024            # a request line from the shell
MAX_INDEX = 256 * 1024          # a provider's frame index
MAX_TILE = 1024 * 1024          # one tile image
MAX_TILES_PER_REQ = 96
MAX_RESULTS = 12
MAX_BASEMAP_POINTS = 240000
MAX_PLACES = 80
TIMEOUT = 10
WORKERS = 4
CACHE_CEILING = 160 * 1024 * 1024
INDEX_TTL = 25                  # seconds an index answer is reused
MAX_DATA_FILE = 64 * 1024 * 1024  # a bundled data file, decompressed

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

# ---------------------------------------------------------------- providers
#
# JMA: the Japan Meteorological Agency's high-resolution precipitation
# nowcast, the same tiles its own site draws. Observed every five minutes with
# three hours kept; the forecast index carries the next hour. Native tiles
# exist to zoom 8 (blank images come back above it).
#
# RainViewer: a composite of national radar networks worldwide, two hours of
# ten-minute frames. The free index gives the tile host; it is checked
# against the allowlist like everything else.

PROVIDERS = {
    "jma": {
        "hosts": ("www.jma.go.jp",),
        "native": 8,
        "past": "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json",
        "forecast": "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N2.json",
        "tile": "https://www.jma.go.jp/bosai/jmatile/data/nowc/{base}/none/{valid}/surf/hrpns/{z}/{x}/{y}.png",
    },
    "rainviewer": {
        "hosts": ("api.rainviewer.com", "tilecache.rainviewer.com"),
        "native": 8,
        "index": "https://api.rainviewer.com/public/weather-maps.json",
        "tile": "{host}{path}/256/{z}/{x}/{y}/{scheme}/1_1.png",
    },
}

ALLOWED_HOSTS = frozenset(h for p in PROVIDERS.values() for h in p["hosts"])

FRAME_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
JMA_TIME = re.compile(r"^\d{14}$")
RV_PATH = re.compile(r"^/v2/radar/[0-9a-f]{6,32}$")


# ------------------------------------------------------------------ output

_out_lock = threading.Lock()


def emit(obj):
    line = json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n"
    with _out_lock:
        try:
            sys.stdout.buffer.write(line.encode("utf-8"))
            sys.stdout.buffer.flush()
        except (BrokenPipeError, OSError):
            os._exit(0)


def log(msg):
    try:
        sys.stderr.write("stormzyd: %s\n" % msg)
        sys.stderr.flush()
    except OSError:
        pass


# ----------------------------------------------------------------- network

class _NoForeignRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        host = urllib.parse.urlsplit(newurl).hostname or ""
        scheme = urllib.parse.urlsplit(newurl).scheme
        if scheme != "https" or host not in ALLOWED_HOSTS:
            raise urllib.error.HTTPError(newurl, code, "redirect refused", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_NoForeignRedirect())


def fetch(url, ceiling):
    """GET `url`, returning at most `ceiling` bytes or raising."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or (parts.hostname or "") not in ALLOWED_HOSTS:
        raise ValueError("host not allowed: %s" % url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "identity"})
    with _opener.open(req, timeout=TIMEOUT) as resp:
        body = resp.read(ceiling + 1)
    if len(body) > ceiling:
        raise ValueError("response over %d bytes" % ceiling)
    return body


# ------------------------------------------------------------------- cache

def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    root = os.path.join(base, "stormzy")
    os.makedirs(root, mode=0o700, exist_ok=True)
    return root


def tile_path(provider, frame, scheme, z, x, y):
    return os.path.join(cache_root(), "tiles", provider, frame, str(scheme), str(z), "%d_%d.png" % (x, y))


def write_atomic(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tile.", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def is_cached(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_size > 0


def cleanup(keep_frames):
    """Drop frame directories no index names any more, then enforce the byte
    ceiling oldest-first. `keep_frames` maps provider -> set of frame ids."""
    tiles = os.path.join(cache_root(), "tiles")
    if not os.path.isdir(tiles):
        return
    entries = []
    for provider in os.listdir(tiles):
        pdir = os.path.join(tiles, provider)
        if not os.path.isdir(pdir) or os.path.islink(pdir):
            continue
        keep = keep_frames.get(provider)
        for frame in os.listdir(pdir):
            fdir = os.path.join(pdir, frame)
            if not os.path.isdir(fdir) or os.path.islink(fdir):
                continue
            size, newest = 0, 0
            for root, dirs, files in os.walk(fdir):
                for name in files:
                    try:
                        st = os.lstat(os.path.join(root, name))
                    except OSError:
                        continue
                    size += st.st_size
                    newest = max(newest, st.st_mtime)
            stale = keep is not None and frame not in keep
            entries.append((stale, newest, size, fdir))
    total = sum(e[2] for e in entries)
    # Stale frames first, then the oldest, until the ceiling is respected.
    entries.sort(key=lambda e: (not e[0], e[1]))
    for stale, newest, size, fdir in entries:
        if not stale and total <= CACHE_CEILING:
            break
        _rmtree(fdir)
        total -= size


def _rmtree(path):
    for root, dirs, files in os.walk(path, topdown=False):
        for name in files:
            try:
                os.unlink(os.path.join(root, name))
            except OSError:
                pass
        for name in dirs:
            try:
                os.rmdir(os.path.join(root, name))
            except OSError:
                pass
    try:
        os.rmdir(path)
    except OSError:
        pass


# ------------------------------------------------------------------ frames

_index_lock = threading.Lock()
_index_cache = {}     # provider -> (time, frames, error)
_known_frames = {}    # provider -> {frame id: tile-url parts}


def jma_frames():
    frames = []
    seen = set()
    for kind, key in (("past", "past"), ("forecast", "forecast")):
        raw = fetch(PROVIDERS["jma"][key], MAX_INDEX)
        entries = json.loads(raw.decode("utf-8"))
        if not isinstance(entries, list):
            raise ValueError("JMA index is not a list")
        for e in entries[:200]:
            if not isinstance(e, dict):
                continue
            base, valid = e.get("basetime"), e.get("validtime")
            if not (isinstance(base, str) and isinstance(valid, str)
                    and JMA_TIME.match(base) and JMA_TIME.match(valid)):
                continue
            fid = "%s_%s" % (base, valid)
            if fid in seen:
                continue
            seen.add(fid)
            frames.append({"id": fid, "time": _jma_epoch(valid), "kind": kind,
                           "_url": {"base": base, "valid": valid}})
    return frames


def _jma_epoch(stamp):
    import calendar
    t = time.strptime(stamp, "%Y%m%d%H%M%S")
    return calendar.timegm(t)


def rainviewer_frames():
    raw = fetch(PROVIDERS["rainviewer"]["index"], MAX_INDEX)
    doc = json.loads(raw.decode("utf-8"))
    if not isinstance(doc, dict):
        raise ValueError("RainViewer index is not an object")
    host = doc.get("host")
    if not isinstance(host, str):
        raise ValueError("RainViewer index has no host")
    hp = urllib.parse.urlsplit(host)
    if hp.scheme != "https" or hp.hostname not in PROVIDERS["rainviewer"]["hosts"] or hp.path not in ("", "/"):
        raise ValueError("RainViewer tile host refused: %s" % host)
    host = "https://" + hp.hostname
    radar = doc.get("radar") if isinstance(doc.get("radar"), dict) else {}
    frames = []
    seen = set()
    for kind, key in (("past", "past"), ("forecast", "nowcast")):
        entries = radar.get(key)
        if not isinstance(entries, list):
            continue
        for e in entries[:100]:
            if not isinstance(e, dict):
                continue
            t, path = e.get("time"), e.get("path")
            if not (isinstance(t, int) and isinstance(path, str) and RV_PATH.match(path)):
                continue
            fid = "%d_%s" % (t, path.rsplit("/", 1)[1])
            if fid in seen:
                continue
            seen.add(fid)
            frames.append({"id": fid, "time": t, "kind": kind, "_url": {"host": host, "path": path}})
    return frames


def frames_for(provider):
    now = time.monotonic()
    with _index_lock:
        hit = _index_cache.get(provider)
        if hit and now - hit[0] < INDEX_TTL:
            return hit[1], hit[2]
    frames, error = [], ""
    try:
        frames = jma_frames() if provider == "jma" else rainviewer_frames()
        frames.sort(key=lambda f: (f["time"], f["kind"] == "forecast"))
    except Exception as e:  # network, JSON, shape: all reported the same way
        error = _short_error(e)
    with _index_lock:
        if frames:
            _known_frames[provider] = {f["id"]: f["_url"] for f in frames}
        _index_cache[provider] = (now, frames, error)
    return frames, error


def _short_error(e):
    if isinstance(e, urllib.error.HTTPError):
        return "HTTP %d" % e.code
    if isinstance(e, urllib.error.URLError):
        return "unreachable"
    if isinstance(e, TimeoutError):
        return "timed out"
    text = str(e) or e.__class__.__name__
    return text[:80]


def public_frame(f):
    return {"id": f["id"], "time": f["time"], "kind": f["kind"]}


# ------------------------------------------------------------------- tiles

_pool = ThreadPoolExecutor(max_workers=WORKERS)


def tile_url(provider, frame, scheme, z, x, y):
    with _index_lock:
        parts = _known_frames.get(provider, {}).get(frame)
    if parts is None:
        return None
    spec = PROVIDERS[provider]["tile"]
    if provider == "jma":
        return spec.format(base=parts["base"], valid=parts["valid"], z=z, x=x, y=y)
    return spec.format(host=parts["host"], path=parts["path"], z=z, x=x, y=y, scheme=scheme)


def get_tile(provider, frame, scheme, z, x, y):
    path = tile_path(provider, frame, scheme, z, x, y)
    if is_cached(path):
        return path
    url = tile_url(provider, frame, scheme, z, x, y)
    if url is None:
        return None
    try:
        data = fetch(url, MAX_TILE)
    except Exception as e:
        log("tile %s: %s" % (url, _short_error(e)))
        return None
    if not data.startswith(PNG_MAGIC):
        return None
    try:
        write_atomic(path, data)
    except OSError as e:
        log("cache write: %s" % e)
        return None
    return path


def handle_tiles(msg):
    req = msg.get("req")
    provider = msg.get("provider")
    frame = msg.get("frame")
    z = msg.get("z")
    scheme = msg.get("scheme", 2)
    tiles = msg.get("tiles")
    ok = (provider in PROVIDERS and isinstance(frame, str) and FRAME_ID.match(frame)
          and isinstance(z, int) and 0 <= z <= 12 and isinstance(scheme, int) and 0 <= scheme <= 8
          and isinstance(tiles, list))
    if not ok:
        emit({"op": "tiles_done", "req": req, "error": "bad request"})
        return
    n = 1 << z
    wanted = []
    for t in tiles[:MAX_TILES_PER_REQ]:
        if (isinstance(t, list) and len(t) == 2 and isinstance(t[0], int) and isinstance(t[1], int)
                and 0 <= t[0] < n and 0 <= t[1] < n):
            wanted.append((t[0], t[1]))

    def one(xy):
        x, y = xy
        path = get_tile(provider, frame, scheme, z, x, y)
        emit({"op": "tile", "req": req, "provider": provider, "frame": frame,
              "z": z, "x": x, "y": y, "scheme": scheme, "file": path})

    futures = [_pool.submit(one, xy) for xy in wanted]

    def finish():
        for f in futures:
            try:
                f.result()
            except Exception as e:
                log("tile job: %s" % e)
        emit({"op": "tiles_done", "req": req, "provider": provider, "frame": frame, "z": z})

    threading.Thread(target=finish, daemon=True).start()


# ------------------------------------------------------------------ search

_cities = None
_countries = None
_country_lookup = None

ALIASES = {
    "uk": "GB", "britain": "GB", "great britain": "GB", "england": "GB", "scotland": "GB",
    "wales": "GB", "usa": "US", "america": "US", "united states of america": "US",
    "u.s.": "US", "u.s.a.": "US", "holland": "NL", "korea": "KR", "russia": "RU",
    "uae": "AE", "nippon": "JP", "nihon": "JP", "czech republic": "CZ", "ivory coast": "CI",
}


def fold(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return s.casefold().strip()


def read_data(name):
    """A bundled data file, decompressed to a ceiling. They ship with the
    plugin, but the read is bounded like every other one here."""
    with gzip.open(os.path.join(DATA_DIR, name), "rb") as f:
        raw = f.read(MAX_DATA_FILE + 1)
    if len(raw) > MAX_DATA_FILE:
        raise ValueError("%s is over %d bytes" % (name, MAX_DATA_FILE))
    return json.loads(raw.decode("utf-8"))


def load_cities():
    global _cities, _countries, _country_lookup
    if _cities is not None:
        return
    doc = read_data("cities.json.gz")
    _countries = doc["countries"]
    rows = []
    for name, ascii_name, cc, adm, lat, lon, pop in doc["cities"]:
        keys = {fold(name)}
        if ascii_name:
            keys.add(fold(ascii_name))
        rows.append((name, cc, adm, lat, lon, pop, tuple(keys), fold(adm) if adm else ""))
    _cities = rows
    _country_lookup = {}
    for cc, cname in _countries.items():
        _country_lookup[fold(cname)] = cc
        _country_lookup[cc.lower()] = cc
    for alias, cc in ALIASES.items():
        _country_lookup[alias] = cc


def search(q):
    load_cities()
    q = fold(q)[:80]
    if not q:
        return []
    parts = [p.strip() for p in q.split(",")]
    name_q = parts[0]
    qualifier = parts[1] if len(parts) > 1 else ""
    cc_filter = None
    adm_filter = ""
    if qualifier:
        cc_filter = _country_lookup.get(qualifier)
        if cc_filter is None:
            adm_filter = qualifier
    # A country on its own lists its biggest cities.
    if not qualifier and name_q in _country_lookup:
        cc = _country_lookup[name_q]
        rows = [r for r in _cities if r[1] == cc][:MAX_RESULTS]
        return [_result(r) for r in rows]
    exact, prefix, word = [], [], []
    for r in _cities:
        if cc_filter and r[1] != cc_filter:
            continue
        if adm_filter and not (r[7].startswith(adm_filter) or fold(_countries.get(r[1], "")).startswith(adm_filter)):
            continue
        for k in r[6]:
            if k == name_q:
                exact.append(r)
                break
            if k.startswith(name_q):
                prefix.append(r)
                break
            if (" " + name_q) in (" " + k) and k.find(" " + name_q) >= 0:
                word.append(r)
                break
        if len(exact) + len(prefix) >= 400:
            break
    out = exact + prefix + word
    return [_result(r) for r in out[:MAX_RESULTS]]


def _result(r):
    name, cc, adm, lat, lon, pop = r[:6]
    return {"name": name, "cc": cc, "country": _countries.get(cc, cc), "admin": adm,
            "lat": lat, "lon": lon, "pop": pop}


# ----------------------------------------------------------------- basemap

_tiers = {}
_places = None
_data_lock = threading.Lock()


def load_tier(tier):
    with _data_lock:
        if tier in _tiers:
            return _tiers[tier]
        doc = read_data("basemap-%s.json.gz" % tier)
        layers = {}
        for layer, lines in doc.items():
            packed = []
            for flat in lines:
                coords = array("f", flat)
                xs = coords[0::2]
                ys = coords[1::2]
                packed.append((min(xs), min(ys), max(xs), max(ys), coords))
            layers[layer] = packed
        _tiers[tier] = layers
        return layers


def load_places():
    global _places
    with _data_lock:
        if _places is None:
            _places = read_data("places.json.gz")
        return _places


def tier_for(zoom):
    if zoom <= 5:
        return "lo"
    if zoom <= 7:
        return "mid"
    return "hi"


def handle_basemap(msg):
    req = msg.get("req")
    zoom = msg.get("zoom")
    bbox = msg.get("bbox")
    if not (isinstance(zoom, (int, float)) and isinstance(bbox, list) and len(bbox) == 4
            and all(isinstance(v, (int, float)) for v in bbox)):
        emit({"op": "basemap", "req": req, "error": "bad request"})
        return
    w, s, e, n = bbox
    zoom = max(0, min(14, float(zoom)))
    layers = load_tier(tier_for(zoom))
    budget = MAX_BASEMAP_POINTS
    out = {}
    for layer in ("lake", "state", "border", "coast"):
        chosen = []
        for (x0, y0, x1, y1, coords) in layers.get(layer, ()):
            if x1 < w or x0 > e or y1 < s or y0 > n:
                continue
            npts = len(coords) // 2
            if npts > budget:
                continue
            budget -= npts
            chosen.append(coords.tolist())
        out[layer] = chosen
    places = []
    for name, lat, lon, min_zoom, pop, capital in load_places():
        if lon < w or lon > e or lat < s or lat > n:
            continue
        if min_zoom > zoom + 1.5:
            continue
        places.append([name, lat, lon, min_zoom, capital])
        if len(places) >= MAX_PLACES:
            break
    emit({"op": "basemap", "req": req, "zoom": zoom, "lines": out, "places": places})


# -------------------------------------------------------------------- main

def handle(msg):
    op = msg.get("op")
    if op == "search":
        q = msg.get("q")
        results = search(q) if isinstance(q, str) else []
        emit({"op": "search", "id": msg.get("id"), "results": results})
    elif op == "frames":
        provider = msg.get("provider")
        if provider not in PROVIDERS:
            emit({"op": "frames", "provider": provider, "frames": [], "error": "unknown provider"})
            return

        def go():
            frames, error = frames_for(provider)
            emit({"op": "frames", "provider": provider, "native": PROVIDERS[provider]["native"],
                  "frames": [public_frame(f) for f in frames], "error": error})
        _pool.submit(go)
    elif op == "tiles":
        handle_tiles(msg)
    elif op == "basemap":
        handle_basemap(msg)
    elif op == "cleanup":
        with _index_lock:
            keep = {p: set(v.keys()) for p, v in _known_frames.items()}
        _pool.submit(cleanup, keep)
    elif op == "hello":
        emit({"op": "hello", "version": VERSION, "providers": sorted(PROVIDERS)})
    else:
        emit({"op": "error", "message": "unknown op"})


def main():
    emit({"op": "hello", "version": VERSION, "providers": sorted(PROVIDERS)})
    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline(MAX_LINE + 1)
        if not line:
            break
        if len(line) > MAX_LINE or not line.endswith(b"\n"):
            # Over-long: discard the rest of it.
            while line and not line.endswith(b"\n"):
                line = stdin.readline(MAX_LINE + 1)
            continue
        try:
            msg = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(msg, dict):
            continue
        try:
            handle(msg)
        except Exception as e:
            log("request failed: %s" % e)
    os._exit(0)


if __name__ == "__main__":
    main()
