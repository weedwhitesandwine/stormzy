.pragma library

// Web Mercator, the projection every tile set here uses. World coordinates
// are pixels at a given integer zoom: 256 * 2^z across the whole world.

var TILE = 256;

function worldSize(z) { return TILE * Math.pow(2, z); }

function lon2x(lon, z) { return (lon + 180) / 360 * worldSize(z); }

function lat2y(lat, z) {
    var r = lat * Math.PI / 180;
    return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * worldSize(z);
}

// Unit coordinates (0..1) are zoom-independent; multiply by worldSize(z).
function lon2u(lon) { return (lon + 180) / 360; }

function lat2v(lat) {
    var r = lat * Math.PI / 180;
    return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2;
}

function x2lon(x, z) { return x / worldSize(z) * 360 - 180; }

function y2lat(y, z) {
    var n = Math.PI - 2 * Math.PI * y / worldSize(z);
    return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
}

function clampLat(lat) { return Math.max(-80, Math.min(80, lat)); }

function wrapLon(lon) {
    while (lon > 180) lon -= 360;
    while (lon < -180) lon += 360;
    return lon;
}

function metersPerPixel(lat, zoom) {
    return 156543.03392 * Math.cos(lat * Math.PI / 180) / Math.pow(2, zoom);
}

// A round distance for a scale bar no wider than maxPx.
function scaleBar(lat, zoom, maxPx) {
    var mpp = metersPerPixel(lat, zoom);
    var maxMeters = mpp * maxPx;
    var steps = [1, 2, 5];
    var best = 1;
    for (var e = 0; e < 8; e++) {
        for (var i = 0; i < steps.length; i++) {
            var m = steps[i] * Math.pow(10, e);
            if (m <= maxMeters) best = m;
        }
    }
    var label = best >= 1000 ? (best / 1000) + " km" : best + " m";
    return { meters: best, px: best / mpp, label: label };
}
