#!/usr/bin/env python3
"""Stormzy's helper: the one process that touches the network or the disk.

Started by the shell (through `setpriv --pdeathsig TERM`, so it cannot outlive
it) and spoken to over stdin/stdout, one JSON object per line. It answers:

  {"op":"search","id":N,"q":"..."}             -> {"op":"search","id":N,"results":[...]}
  {"op":"frames","source":S}                    -> {"op":"frames","source":S,"native":Z,"frames":[...],"error":""}
  {"op":"tiles","req":N,"source":S,"frame":F,
   "z":Z,"scheme":C,"tiles":[[x,y],...]}        -> {"op":"tile",...,"file":path|null} per tile,
                                                   then {"op":"tiles_done","req":N}
  {"op":"grid","req":N,"kind":"weather"|"air",
   "lats":[...],"lons":[...]}                   -> {"op":"grid","req":N,"kind":K,"time":T,"points":[...],"error":""}
  {"op":"stations","req":N,"bbox":[w,s,e,n]}    -> {"op":"stations","req":N,"time":T,"points":[...],"error":""}
  {"op":"basemap","req":N,"zoom":Z,"bbox":[w,s,e,n]}
                                                -> {"op":"basemap","req":N,"lines":{...},"places":[...]}
  {"op":"cleanup"}                              -> prunes the tile cache

Network: only the hosts named in SOURCES and APIS are ever contacted, over
HTTPS, with a ten-second timeout, and every body is read to a ceiling plus one
byte and refused above it. A redirect to any other host is refused. Nothing
is sent beyond the request itself and a User-Agent naming this plugin.

Disk: tiles and the AMeDAS station table land under $XDG_CACHE_HOME/stormzy
(default ~/.cache/stormzy), written to a random temporary name and renamed
into place. The bundled data under the plugin's data/ directory is read,
never written.
"""
import calendar
import gzip
import json
import os
import re
import stat
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

VERSION = "0.2.0"
USER_AGENT = "stormzy/%s (Omarchy plugin; https://github.com/weedwhitesandwine/stormzy)" % VERSION

HERE = os.path.dirname(os.path.realpath(__file__))
DATA_DIR = os.path.join(HERE, "data")

MAX_LINE = 64 * 1024            # a request line from the shell
MAX_INDEX = 256 * 1024          # a provider's frame index
MAX_TILE = 1024 * 1024          # one tile image
MAX_API = 1024 * 1024           # an Open-Meteo answer or the AMeDAS map
MAX_STATION_TABLE = 2 * 1024 * 1024
MAX_DATA_FILE = 64 * 1024 * 1024  # a bundled data file, decompressed
MAX_TILES_PER_REQ = 96
MAX_GRID_POINTS = 100
MAX_STATIONS = 400
MAX_RESULTS = 12
MAX_BASEMAP_POINTS = 240000
MAX_PLACES = 80
TIMEOUT = 10
WORKERS = 4
CACHE_CEILING = 160 * 1024 * 1024
INDEX_TTL = 25                  # seconds an index answer is reused
GRID_TTL = 600                  # seconds an Open-Meteo or AMeDAS answer is reused
STATION_TABLE_TTL = 7 * 86400

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_MAGIC = b"\xff\xd8\xff"

# ----------------------------------------------------------------- sources
#
# Tile sources. Each has a frame index (or a single "now" frame) and a tile
# URL. `native` is the finest zoom with real tiles; the map scales beyond it.
#
# jma        JMA high-resolution precipitation nowcast: 5-minute, three hours
#            kept, one hour of forecast. Blank above zoom 8.
# rainviewer RainViewer's composite of national radars: ten-minute, two hours.
# jma_temp   JMA weather-distribution temperature: three-hourly, about a day
#            ahead. Blank above zoom 7.
# himawari   Himawari infrared (band 13) full-disk imagery from JMA, ten-minute.
#            Tiles exist to zoom 5.
# waqi       World Air Quality Index station markers, one live layer.

SOURCES = {
    "jma": {
        "hosts": ("www.jma.go.jp",), "native": 8,
        "tile": "https://www.jma.go.jp/bosai/jmatile/data/nowc/{base}/none/{valid}/surf/hrpns/{z}/{x}/{y}.png",
    },
    "rainviewer": {
        "hosts": ("api.rainviewer.com", "tilecache.rainviewer.com"), "native": 8,
        "index": "https://api.rainviewer.com/public/weather-maps.json",
        "tile": "{host}{path}/256/{z}/{x}/{y}/{scheme}/1_1.png",
    },
    "jma_temp": {
        "hosts": ("www.jma.go.jp",), "native": 7,
        "index": "https://www.jma.go.jp/bosai/jmatile/data/wdist/targetTimes.json",
        "tile": "https://www.jma.go.jp/bosai/jmatile/data/wdist/{base}/none/{valid}/surf/temp/{z}/{x}/{y}.png",
    },
    "himawari": {
        "hosts": ("www.jma.go.jp",), "native": 5,
        "index": "https://www.jma.go.jp/bosai/himawari/data/satimg/targetTimes_fd.json",
        "tile": "https://www.jma.go.jp/bosai/himawari/data/satimg/{base}/fd/{valid}/B13/TBB/{z}/{x}/{y}.jpg",
    },
    "waqi": {
        "hosts": ("tiles.aqicn.org",), "native": 11,
        "tile": "https://tiles.aqicn.org/tiles/usepa-aqi/{z}/{x}/{y}.png",
    },
}

JMA_NOWC_PAST = "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json"
JMA_NOWC_FORECAST = "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N2.json"

# Point APIs, drawn as numbers and arrows rather than tiles.
APIS = {
    "weather": "https://api.open-meteo.com/v1/forecast",
    "air": "https://air-quality-api.open-meteo.com/v1/air-quality",
    "amedas_latest": "https://www.jma.go.jp/bosai/amedas/data/latest_time.txt",
    "amedas_map": "https://www.jma.go.jp/bosai/amedas/data/map/{stamp}.json",
    "amedas_table": "https://www.jma.go.jp/bosai/amedas/const/amedastable.json",
}
API_HOSTS = ("api.open-meteo.com", "air-quality-api.open-meteo.com", "www.jma.go.jp")

ALLOWED_HOSTS = frozenset(h for p in SOURCES.values() for h in p["hosts"]) | frozenset(API_HOSTS)

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


def fetch_json(url, ceiling):
    return json.loads(fetch(url, ceiling).decode("utf-8"))


def _short_error(e):
    if isinstance(e, urllib.error.HTTPError):
        return "HTTP %d" % e.code
    if isinstance(e, urllib.error.URLError):
        return "unreachable"
    if isinstance(e, TimeoutError):
        return "timed out"
    text = str(e) or e.__class__.__name__
    return text[:80]


# ------------------------------------------------------------------- cache

def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    root = os.path.join(base, "stormzy")
    os.makedirs(root, mode=0o700, exist_ok=True)
    return root


def tile_path(source, frame, scheme, z, x, y):
    ext = "jpg" if source == "himawari" else "png"
    return os.path.join(cache_root(), "tiles", source, frame, str(scheme), str(z), "%d_%d.%s" % (x, y, ext))


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


def read_cached(path, ceiling):
    """A file under our cache: refused unless a plain file under the ceiling."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None, 0
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, 0
        with os.fdopen(fd, "rb") as f:
            fd = None
            raw = f.read(ceiling + 1)
    except OSError:
        return None, 0
    finally:
        if fd is not None:
            os.close(fd)
    if len(raw) > ceiling:
        return None, 0
    return raw, st.st_mtime


def is_cached(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_size > 0


def cleanup(keep_frames):
    """Drop frame directories no index names any more, then enforce the byte
    ceiling oldest-first. `keep_frames` maps source -> set of frame ids."""
    tiles = os.path.join(cache_root(), "tiles")
    if not os.path.isdir(tiles):
        return
    entries = []
    for source in os.listdir(tiles):
        sdir = os.path.join(tiles, source)
        if not os.path.isdir(sdir) or os.path.islink(sdir):
            continue
        keep = keep_frames.get(source)
        for frame in os.listdir(sdir):
            fdir = os.path.join(sdir, frame)
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
_index_cache = {}     # source -> (time, frames, error)
_known_frames = {}    # source -> {frame id: tile-url parts}


def _jma_epoch(stamp):
    return calendar.timegm(time.strptime(stamp, "%Y%m%d%H%M%S"))


def _jma_entries(url, want_element=None, limit=200):
    entries = fetch_json(url, MAX_INDEX)
    if not isinstance(entries, list):
        raise ValueError("index is not a list")
    out = []
    for e in entries[:limit]:
        if not isinstance(e, dict):
            continue
        base, valid = e.get("basetime"), e.get("validtime")
        if not (isinstance(base, str) and isinstance(valid, str)
                and JMA_TIME.match(base) and JMA_TIME.match(valid)):
            continue
        if want_element is not None:
            elems = e.get("elements")
            if not isinstance(elems, list) or want_element not in elems:
                continue
        out.append((base, valid))
    return out


def jma_frames():
    frames, seen = [], set()
    for kind, url in (("past", JMA_NOWC_PAST), ("forecast", JMA_NOWC_FORECAST)):
        for base, valid in _jma_entries(url):
            fid = "%s_%s" % (base, valid)
            if fid in seen:
                continue
            seen.add(fid)
            frames.append({"id": fid, "time": _jma_epoch(valid), "kind": kind, "_url": {"base": base, "valid": valid}})
    return frames


def jma_temp_frames():
    now = time.time()
    frames, seen = [], set()
    for base, valid in _jma_entries(SOURCES["jma_temp"]["index"], "temp"):
        fid = "%s_%s" % (base, valid)
        if fid in seen:
            continue
        seen.add(fid)
        t = _jma_epoch(valid)
        frames.append({"id": fid, "time": t, "kind": "forecast" if t > now + 1800 else "past",
                       "_url": {"base": base, "valid": valid}})
    return frames


def himawari_frames():
    entries = _jma_entries(SOURCES["himawari"]["index"], None, 400)
    entries.sort(key=lambda bv: bv[1])
    frames = []
    for base, valid in entries[-18:]:
        frames.append({"id": "%s_%s" % (base, valid), "time": _jma_epoch(valid), "kind": "past",
                       "_url": {"base": base, "valid": valid}})
    return frames


def rainviewer_frames():
    doc = fetch_json(SOURCES["rainviewer"]["index"], MAX_INDEX)
    if not isinstance(doc, dict):
        raise ValueError("RainViewer index is not an object")
    host = doc.get("host")
    if not isinstance(host, str):
        raise ValueError("RainViewer index has no host")
    hp = urllib.parse.urlsplit(host)
    if hp.scheme != "https" or hp.hostname not in SOURCES["rainviewer"]["hosts"] or hp.path not in ("", "/"):
        raise ValueError("RainViewer tile host refused: %s" % host)
    host = "https://" + hp.hostname
    radar = doc.get("radar") if isinstance(doc.get("radar"), dict) else {}
    frames, seen = [], set()
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


def waqi_frames():
    # One live layer. A tiny probe tile says whether the service answers; the
    # frame id changes every ten minutes so the cache refreshes.
    data = fetch(SOURCES["waqi"]["tile"].format(z=2, x=1, y=1), MAX_TILE)
    if not data.startswith(PNG_MAGIC):
        raise ValueError("not an image")
    now = int(time.time())
    bucket = now // 600
    return [{"id": "b%d" % bucket, "time": bucket * 600, "kind": "past", "_url": {}}]


FRAME_FETCHERS = {
    "jma": jma_frames, "rainviewer": rainviewer_frames, "jma_temp": jma_temp_frames,
    "himawari": himawari_frames, "waqi": waqi_frames,
}


def frames_for(source):
    now = time.monotonic()
    with _index_lock:
        hit = _index_cache.get(source)
        if hit and now - hit[0] < INDEX_TTL:
            return hit[1], hit[2]
    frames, error = [], ""
    try:
        frames = FRAME_FETCHERS[source]()
        frames.sort(key=lambda f: (f["time"], f["kind"] == "forecast"))
    except Exception as e:  # network, JSON, shape: all reported the same way
        error = _short_error(e)
    with _index_lock:
        if frames:
            _known_frames[source] = {f["id"]: f["_url"] for f in frames}
        _index_cache[source] = (now, frames, error)
    return frames, error


def public_frame(f):
    return {"id": f["id"], "time": f["time"], "kind": f["kind"]}


# ------------------------------------------------------------------- tiles

_pool = ThreadPoolExecutor(max_workers=WORKERS)


def tile_url(source, frame, scheme, z, x, y):
    with _index_lock:
        parts = _known_frames.get(source, {}).get(frame)
    if parts is None:
        return None
    spec = SOURCES[source]["tile"]
    if source == "rainviewer":
        return spec.format(host=parts["host"], path=parts["path"], z=z, x=x, y=y, scheme=scheme)
    if source == "waqi":
        return spec.format(z=z, x=x, y=y)
    return spec.format(base=parts["base"], valid=parts["valid"], z=z, x=x, y=y)


def get_tile(source, frame, scheme, z, x, y):
    path = tile_path(source, frame, scheme, z, x, y)
    if is_cached(path):
        return path
    url = tile_url(source, frame, scheme, z, x, y)
    if url is None:
        return None
    try:
        data = fetch(url, MAX_TILE)
    except Exception as e:
        log("tile %s: %s" % (url, _short_error(e)))
        return None
    if not (data.startswith(PNG_MAGIC) or data.startswith(JPEG_MAGIC)):
        return None
    try:
        write_atomic(path, data)
    except OSError as e:
        log("cache write: %s" % e)
        return None
    return path


def handle_tiles(msg):
    req = msg.get("req")
    source = msg.get("source")
    frame = msg.get("frame")
    z = msg.get("z")
    scheme = msg.get("scheme", 2)
    tiles = msg.get("tiles")
    ok = (source in SOURCES and isinstance(frame, str) and FRAME_ID.match(frame)
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
        path = get_tile(source, frame, scheme, z, x, y)
        emit({"op": "tile", "req": req, "source": source, "frame": frame,
              "z": z, "x": x, "y": y, "scheme": scheme, "file": path})

    futures = [_pool.submit(one, xy) for xy in wanted]

    def finish():
        for f in futures:
            try:
                f.result()
            except Exception as e:
                log("tile job: %s" % e)
        emit({"op": "tiles_done", "req": req, "source": source, "frame": frame, "z": z})

    threading.Thread(target=finish, daemon=True).start()


# -------------------------------------------------------------- point data

_grid_lock = threading.Lock()
_grid_cache = {}   # key -> (monotonic, result)


def _num(v):
    return v if isinstance(v, (int, float)) and v == v else None


def _mid_stamp(doc):
    """The time of the grid's centre point, in that point's own zone. The
    first point can sit at sea, where the zone comes back as UTC."""
    order = [len(doc) // 2] + list(range(len(doc)))
    for i in order:
        d = doc[i] if i < len(doc) else None
        if isinstance(d, dict) and isinstance(d.get("current"), dict):
            t = d["current"].get("time")
            if isinstance(t, str) and t:
                return t[:16]
    return ""


def grid_weather(lats, lons):
    url = APIS["weather"] + "?" + urllib.parse.urlencode({
        "latitude": ",".join("%.3f" % v for v in lats),
        "longitude": ",".join("%.3f" % v for v in lons),
        "current": "temperature_2m,wind_speed_10m,wind_direction_10m",
        "wind_speed_unit": "ms",
        "timezone": "auto",
    })
    doc = fetch_json(url, MAX_API)
    if isinstance(doc, dict):
        doc = [doc]
    if not isinstance(doc, list):
        raise ValueError("unexpected answer")
    points, stamp = [], _mid_stamp(doc)
    for i, d in enumerate(doc[:MAX_GRID_POINTS]):
        if not isinstance(d, dict) or not isinstance(d.get("current"), dict):
            continue
        c = d["current"]
        points.append({"lat": lats[i], "lon": lons[i], "t": _num(c.get("temperature_2m")),
                       "ws": _num(c.get("wind_speed_10m")), "wd": _num(c.get("wind_direction_10m"))})
    return stamp, points


def grid_air(lats, lons):
    url = APIS["air"] + "?" + urllib.parse.urlencode({
        "latitude": ",".join("%.3f" % v for v in lats),
        "longitude": ",".join("%.3f" % v for v in lons),
        "current": "us_aqi,european_aqi,pm2_5",
        "timezone": "auto",
    })
    doc = fetch_json(url, MAX_API)
    if isinstance(doc, dict):
        doc = [doc]
    if not isinstance(doc, list):
        raise ValueError("unexpected answer")
    points, stamp = [], _mid_stamp(doc)
    for i, d in enumerate(doc[:MAX_GRID_POINTS]):
        if not isinstance(d, dict) or not isinstance(d.get("current"), dict):
            continue
        c = d["current"]
        points.append({"lat": lats[i], "lon": lons[i], "aqi": _num(c.get("us_aqi")),
                       "eaqi": _num(c.get("european_aqi")), "pm25": _num(c.get("pm2_5"))})
    return stamp, points


def handle_grid(msg):
    req = msg.get("req")
    kind = msg.get("kind")
    lats, lons = msg.get("lats"), msg.get("lons")
    ok = (kind in ("weather", "air") and isinstance(lats, list) and isinstance(lons, list)
          and 0 < len(lats) == len(lons) <= MAX_GRID_POINTS
          and all(isinstance(v, (int, float)) and -85 <= v <= 85 for v in lats)
          and all(isinstance(v, (int, float)) and -180 <= v <= 180 for v in lons))
    if not ok:
        emit({"op": "grid", "req": req, "kind": kind, "points": [], "error": "bad request"})
        return
    lats = [round(float(v), 3) for v in lats]
    lons = [round(float(v), 3) for v in lons]
    key = kind + "|" + ",".join("%.3f/%.3f" % p for p in zip(lats, lons))

    def go():
        now = time.monotonic()
        with _grid_lock:
            hit = _grid_cache.get(key)
        if hit and now - hit[0] < GRID_TTL:
            stamp, points, error = hit[1]
        else:
            stamp, points, error = "", [], ""
            try:
                stamp, points = grid_weather(lats, lons) if kind == "weather" else grid_air(lats, lons)
            except Exception as e:
                error = _short_error(e)
            with _grid_lock:
                if not error:
                    _grid_cache[key] = (now, (stamp, points, error))
                if len(_grid_cache) > 64:
                    oldest = min(_grid_cache, key=lambda k: _grid_cache[k][0])
                    del _grid_cache[oldest]
        emit({"op": "grid", "req": req, "kind": kind, "time": stamp, "points": points, "error": error})
    _pool.submit(go)


# ------------------------------------------------------------------ AMeDAS
#
# JMA's surface observation network: temperature and wind at every station,
# every ten minutes. The station table (positions and names) is fetched once
# a week and kept on disk; the observations are kept for ten minutes.

_amedas_lock = threading.Lock()
_amedas_table = None      # {id: (lat, lon, name)}
_amedas_data = None       # (monotonic, stamp, {id: {...}})


def amedas_table():
    global _amedas_table
    with _amedas_lock:
        if _amedas_table is not None:
            return _amedas_table
    path = os.path.join(cache_root(), "amedastable.json")
    raw, mtime = read_cached(path, MAX_STATION_TABLE)
    doc = None
    if raw is not None and time.time() - mtime < STATION_TABLE_TTL:
        try:
            doc = json.loads(raw.decode("utf-8"))
        except ValueError:
            doc = None
    if doc is None:
        raw = fetch(APIS["amedas_table"], MAX_STATION_TABLE)
        doc = json.loads(raw.decode("utf-8"))
        try:
            write_atomic(path, raw)
        except OSError as e:
            log("station table write: %s" % e)
    if not isinstance(doc, dict):
        raise ValueError("station table is not an object")
    table = {}
    for sid, row in doc.items():
        if not isinstance(row, dict) or not isinstance(sid, str) or len(sid) > 8:
            continue
        lat, lon = row.get("lat"), row.get("lon")
        if not (isinstance(lat, list) and isinstance(lon, list) and len(lat) == 2 and len(lon) == 2):
            continue
        try:
            la = float(lat[0]) + float(lat[1]) / 60.0
            lo = float(lon[0]) + float(lon[1]) / 60.0
        except (TypeError, ValueError):
            continue
        name = row.get("enName") or row.get("kjName") or ""
        table[sid] = (round(la, 4), round(lo, 4), str(name)[:40])
    with _amedas_lock:
        _amedas_table = table
    return table


def amedas_data():
    global _amedas_data
    now = time.monotonic()
    with _amedas_lock:
        if _amedas_data and now - _amedas_data[0] < GRID_TTL:
            return _amedas_data[1], _amedas_data[2]
    latest = fetch(APIS["amedas_latest"], 1024).decode("ascii", "replace").strip()
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})", latest)
    if not m:
        raise ValueError("bad latest_time")
    stamp = "".join(m.groups()) + "00"
    doc = fetch_json(APIS["amedas_map"].format(stamp=stamp), MAX_API)
    if not isinstance(doc, dict):
        raise ValueError("observations are not an object")
    with _amedas_lock:
        _amedas_data = (now, latest[:16], doc)
    return latest[:16], doc


def handle_stations(msg):
    req = msg.get("req")
    bbox = msg.get("bbox")
    if not (isinstance(bbox, list) and len(bbox) == 4 and all(isinstance(v, (int, float)) for v in bbox)):
        emit({"op": "stations", "req": req, "points": [], "error": "bad request"})
        return
    w, s, e, n = [float(v) for v in bbox]

    def go():
        try:
            table = amedas_table()
            stamp, data = amedas_data()
        except Exception as ex:
            emit({"op": "stations", "req": req, "points": [], "error": _short_error(ex)})
            return
        points = []
        for sid, (lat, lon, name) in table.items():
            if lon < w or lon > e or lat < s or lat > n:
                continue
            row = data.get(sid)
            if not isinstance(row, dict):
                continue
            t = row.get("temp")
            ws = row.get("wind")
            wd = row.get("windDirection")
            t = _num(t[0]) if isinstance(t, list) and t else None
            ws = _num(ws[0]) if isinstance(ws, list) and ws else None
            wd = _num(wd[0]) if isinstance(wd, list) and wd else None
            # Direction is a 16-point compass index; 0 means calm.
            deg = None if wd is None or wd <= 0 else (wd * 22.5) % 360
            if t is None and ws is None:
                continue
            points.append({"lat": lat, "lon": lon, "name": name, "t": t, "ws": ws, "wd": deg})
            if len(points) >= MAX_STATIONS:
                break
        emit({"op": "stations", "req": req, "time": stamp, "points": points, "error": ""})
    _pool.submit(go)


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
            if k.find(" " + name_q) >= 0:
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
        source = msg.get("source")
        if source not in SOURCES:
            emit({"op": "frames", "source": source, "frames": [], "error": "unknown source"})
            return

        def go():
            frames, error = frames_for(source)
            emit({"op": "frames", "source": source, "native": SOURCES[source]["native"],
                  "frames": [public_frame(f) for f in frames], "error": error})
        _pool.submit(go)
    elif op == "tiles":
        handle_tiles(msg)
    elif op == "grid":
        handle_grid(msg)
    elif op == "stations":
        handle_stations(msg)
    elif op == "basemap":
        handle_basemap(msg)
    elif op == "cleanup":
        with _index_lock:
            keep = {p: set(v.keys()) for p, v in _known_frames.items()}
        _pool.submit(cleanup, keep)
    elif op == "hello":
        emit({"op": "hello", "version": VERSION, "sources": sorted(SOURCES)})
    else:
        emit({"op": "error", "message": "unknown op"})


def main():
    emit({"op": "hello", "version": VERSION, "sources": sorted(SOURCES)})
    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline(MAX_LINE + 1)
        if not line:
            break
        if len(line) > MAX_LINE or not line.endswith(b"\n"):
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
