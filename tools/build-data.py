#!/usr/bin/env python3
"""Build Stormzy's bundled data files from their public sources.

A development tool: it is run once by hand to regenerate the files under
data/, and never by the plugin. Inputs (all public, see data/README.md):

  natural-earth-vector GeoJSON (public domain):
    ne_10m_coastline, ne_50m_coastline,
    ne_10m_admin_0_boundary_lines_land, ne_50m_admin_0_boundary_lines_land,
    ne_10m_admin_1_states_provinces_lines, ne_50m_admin_1_states_provinces_lines,
    ne_10m_lakes, ne_50m_lakes, ne_10m_populated_places (places.geojson)
  GeoNames (CC BY 4.0): cities5000.txt, admin1CodesASCII.txt

Usage:
  build-data.py <source dir> <output dir>

Every input may be plain or gzip-compressed (.gz). Outputs:
  cities.json.gz      the gazetteer the place search runs over
  places.json.gz      map labels (Natural Earth populated places)
  basemap-lo.json.gz  coast/borders/states/lakes for zoom <= 5
  basemap-mid.json.gz                             for zoom 6-7
  basemap-hi.json.gz                              for zoom >= 8
"""
import gzip
import json
import math
import os
import sys

COUNTRIES = {
 "AD":"Andorra","AE":"United Arab Emirates","AF":"Afghanistan","AG":"Antigua and Barbuda","AI":"Anguilla","AL":"Albania","AM":"Armenia","AO":"Angola","AQ":"Antarctica","AR":"Argentina","AS":"American Samoa","AT":"Austria","AU":"Australia","AW":"Aruba","AX":"Aland Islands","AZ":"Azerbaijan","BA":"Bosnia and Herzegovina","BB":"Barbados","BD":"Bangladesh","BE":"Belgium","BF":"Burkina Faso","BG":"Bulgaria","BH":"Bahrain","BI":"Burundi","BJ":"Benin","BL":"Saint Barthelemy","BM":"Bermuda","BN":"Brunei","BO":"Bolivia","BQ":"Bonaire","BR":"Brazil","BS":"Bahamas","BT":"Bhutan","BV":"Bouvet Island","BW":"Botswana","BY":"Belarus","BZ":"Belize","CA":"Canada","CC":"Cocos Islands","CD":"DR Congo","CF":"Central African Republic","CG":"Congo","CH":"Switzerland","CI":"Ivory Coast","CK":"Cook Islands","CL":"Chile","CM":"Cameroon","CN":"China","CO":"Colombia","CR":"Costa Rica","CU":"Cuba","CV":"Cape Verde","CW":"Curacao","CX":"Christmas Island","CY":"Cyprus","CZ":"Czechia","DE":"Germany","DJ":"Djibouti","DK":"Denmark","DM":"Dominica","DO":"Dominican Republic","DZ":"Algeria","EC":"Ecuador","EE":"Estonia","EG":"Egypt","EH":"Western Sahara","ER":"Eritrea","ES":"Spain","ET":"Ethiopia","FI":"Finland","FJ":"Fiji","FK":"Falkland Islands","FM":"Micronesia","FO":"Faroe Islands","FR":"France","GA":"Gabon","GB":"United Kingdom","GD":"Grenada","GE":"Georgia","GF":"French Guiana","GG":"Guernsey","GH":"Ghana","GI":"Gibraltar","GL":"Greenland","GM":"Gambia","GN":"Guinea","GP":"Guadeloupe","GQ":"Equatorial Guinea","GR":"Greece","GS":"South Georgia","GT":"Guatemala","GU":"Guam","GW":"Guinea-Bissau","GY":"Guyana","HK":"Hong Kong","HM":"Heard Island","HN":"Honduras","HR":"Croatia","HT":"Haiti","HU":"Hungary","ID":"Indonesia","IE":"Ireland","IL":"Israel","IM":"Isle of Man","IN":"India","IO":"British Indian Ocean Territory","IQ":"Iraq","IR":"Iran","IS":"Iceland","IT":"Italy","JE":"Jersey","JM":"Jamaica","JO":"Jordan","JP":"Japan","KE":"Kenya","KG":"Kyrgyzstan","KH":"Cambodia","KI":"Kiribati","KM":"Comoros","KN":"Saint Kitts and Nevis","KP":"North Korea","KR":"South Korea","KW":"Kuwait","KY":"Cayman Islands","KZ":"Kazakhstan","LA":"Laos","LB":"Lebanon","LC":"Saint Lucia","LI":"Liechtenstein","LK":"Sri Lanka","LR":"Liberia","LS":"Lesotho","LT":"Lithuania","LU":"Luxembourg","LV":"Latvia","LY":"Libya","MA":"Morocco","MC":"Monaco","MD":"Moldova","ME":"Montenegro","MF":"Saint Martin","MG":"Madagascar","MH":"Marshall Islands","MK":"North Macedonia","ML":"Mali","MM":"Myanmar","MN":"Mongolia","MO":"Macao","MP":"Northern Mariana Islands","MQ":"Martinique","MR":"Mauritania","MS":"Montserrat","MT":"Malta","MU":"Mauritius","MV":"Maldives","MW":"Malawi","MX":"Mexico","MY":"Malaysia","MZ":"Mozambique","NA":"Namibia","NC":"New Caledonia","NE":"Niger","NF":"Norfolk Island","NG":"Nigeria","NI":"Nicaragua","NL":"Netherlands","NO":"Norway","NP":"Nepal","NR":"Nauru","NU":"Niue","NZ":"New Zealand","OM":"Oman","PA":"Panama","PE":"Peru","PF":"French Polynesia","PG":"Papua New Guinea","PH":"Philippines","PK":"Pakistan","PL":"Poland","PM":"Saint Pierre and Miquelon","PN":"Pitcairn","PR":"Puerto Rico","PS":"Palestine","PT":"Portugal","PW":"Palau","PY":"Paraguay","QA":"Qatar","RE":"Reunion","RO":"Romania","RS":"Serbia","RU":"Russia","RW":"Rwanda","SA":"Saudi Arabia","SB":"Solomon Islands","SC":"Seychelles","SD":"Sudan","SE":"Sweden","SG":"Singapore","SH":"Saint Helena","SI":"Slovenia","SJ":"Svalbard","SK":"Slovakia","SL":"Sierra Leone","SM":"San Marino","SN":"Senegal","SO":"Somalia","SR":"Suriname","SS":"South Sudan","ST":"Sao Tome and Principe","SV":"El Salvador","SX":"Sint Maarten","SY":"Syria","SZ":"Eswatini","TC":"Turks and Caicos Islands","TD":"Chad","TF":"French Southern Territories","TG":"Togo","TH":"Thailand","TJ":"Tajikistan","TK":"Tokelau","TL":"Timor-Leste","TM":"Turkmenistan","TN":"Tunisia","TO":"Tonga","TR":"Turkey","TT":"Trinidad and Tobago","TV":"Tuvalu","TW":"Taiwan","TZ":"Tanzania","UA":"Ukraine","UG":"Uganda","UM":"US Minor Outlying Islands","US":"United States","UY":"Uruguay","UZ":"Uzbekistan","VA":"Vatican City","VC":"Saint Vincent and the Grenadines","VE":"Venezuela","VG":"British Virgin Islands","VI":"US Virgin Islands","VN":"Vietnam","VU":"Vanuatu","WF":"Wallis and Futuna","WS":"Samoa","XK":"Kosovo","YE":"Yemen","YT":"Mayotte","ZA":"South Africa","ZM":"Zambia","ZW":"Zimbabwe",
}


def open_any(directory, name):
    for cand in (name, name + ".gz"):
        p = os.path.join(directory, cand)
        if os.path.exists(p):
            if cand.endswith(".gz"):
                return gzip.open(p, "rt", encoding="utf-8")
            return open(p, "r", encoding="utf-8")
    raise SystemExit("missing input: %s (or .gz) in %s" % (name, directory))


def write_gz(path, obj):
    raw = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    with gzip.open(path, "wb", compresslevel=9) as f:
        f.write(raw)
    print("%-22s %8d KB raw, %6d KB gz" % (os.path.basename(path), len(raw) // 1024, os.path.getsize(path) // 1024))


# ---------------------------------------------------------------- geometry

def simplify(points, tol):
    """Douglas-Peucker on [(lon, lat), ...], iterative. tol in degrees."""
    n = len(points)
    if n < 3 or tol <= 0:
        return points
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    tol2 = tol * tol
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        seg2 = dx * dx + dy * dy
        best, best_i = 0.0, -1
        for i in range(a + 1, b):
            px, py = points[i]
            if seg2 == 0:
                d2 = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / seg2
                t = 0.0 if t < 0 else 1.0 if t > 1 else t
                qx, qy = ax + t * dx, ay + t * dy
                d2 = (px - qx) ** 2 + (py - qy) ** 2
            if d2 > best:
                best, best_i = d2, i
        if best > tol2:
            keep[best_i] = True
            stack.append((a, best_i))
            stack.append((best_i, b))
    return [p for p, k in zip(points, keep) if k]


def lines_of(geom):
    t = geom.get("type")
    c = geom.get("coordinates") or []
    if t == "LineString":
        return [c]
    if t == "MultiLineString":
        return list(c)
    if t == "Polygon":
        return list(c)
    if t == "MultiPolygon":
        return [ring for poly in c for ring in poly]
    return []


def collect(directory, name, tol, min_points=2):
    src = json.load(open_any(directory, name))
    out = []
    total_in = 0
    for feat in src.get("features", []):
        for line in lines_of(feat.get("geometry") or {}):
            pts = [(float(p[0]), float(p[1])) for p in line if len(p) >= 2]
            total_in += len(pts)
            pts = simplify(pts, tol)
            if len(pts) < min_points:
                continue
            flat = []
            for lon, lat in pts:
                flat.append(round(lon, 4))
                flat.append(round(lat, 4))
            out.append(flat)
    print("  %-48s %7d -> %7d points, %5d lines" % (name, total_in, sum(len(l) // 2 for l in out), len(out)))
    return out


def build_basemap(src, out_dir):
    tiers = [
        ("lo", "50m", 0.03),
        ("mid", "10m", 0.01),
        ("hi", "10m", 0.003),
    ]
    for tier, res, tol in tiers:
        print("basemap-%s (%s, tolerance %g deg)" % (tier, res, tol))
        data = {
            "coast": collect(src, "ne_%s_coastline.geojson" % res, tol),
            "border": collect(src, "ne_%s_admin_0_boundary_lines_land.geojson" % res, tol),
            "state": collect(src, "ne_%s_admin_1_states_provinces_lines.geojson" % res, tol),
            "lake": collect(src, "ne_%s_lakes.geojson" % res, tol, 4),
        }
        write_gz(os.path.join(out_dir, "basemap-%s.json.gz" % tier), data)


def build_places(src, out_dir):
    feats = json.load(open_any(src, "places.geojson")).get("features", [])
    rows = []
    for f in feats:
        p = f.get("properties") or {}
        g = f.get("geometry") or {}
        c = g.get("coordinates") or []
        if g.get("type") != "Point" or len(c) < 2:
            continue
        name = p.get("name") or p.get("nameascii") or ""
        if not name:
            continue
        rows.append([
            name,
            round(float(c[1]), 4),
            round(float(c[0]), 4),
            int(p.get("min_zoom") or 10),
            int(p.get("pop_max") or 0),
            1 if p.get("adm0cap") else 0,
        ])
    rows.sort(key=lambda r: (-r[5], -r[4]))
    write_gz(os.path.join(out_dir, "places.json.gz"), rows)


def build_cities(src, out_dir):
    admin = {}
    for line in open_any(src, "admin1CodesASCII.txt"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            admin[parts[0]] = parts[1]
    rows = []
    for line in open_any(src, "cities5000.txt"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 15:
            continue
        name, ascii_name = p[1], p[2]
        try:
            lat, lon = float(p[4]), float(p[5])
            pop = int(p[14] or 0)
        except ValueError:
            continue
        cc = p[8]
        adm = admin.get("%s.%s" % (cc, p[10]), "")
        rows.append([name, ascii_name if ascii_name != name else "", cc, adm,
                     round(lat, 4), round(lon, 4), pop])
    rows.sort(key=lambda r: -r[6])
    write_gz(os.path.join(out_dir, "cities.json.gz"),
             {"countries": COUNTRIES, "cities": rows})


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    build_cities(src, out_dir)
    build_places(src, out_dir)
    build_basemap(src, out_dir)


if __name__ == "__main__":
    main()
