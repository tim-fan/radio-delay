#!/usr/bin/env python3
"""Maintain a cache of per-chunk audio metadata.

Usage: mp3dur.py <cache.json> <chunkdir> [chunk_seconds]

Scans <chunkdir> for completed chunks (mtime older than 15 s) not yet in
the cache and records, per chunk:

  d  measured audio duration, from walking MP3 frame headers — every
     frame declares its own bitrate, so this is exact regardless of the
     stream's configured bitrate, VBR, or corrupt spans between frames
  c  intended coverage: seconds from the chunk's start to the next
     chunk-grid boundary (a post-reconnect chunk starting mid-window is
     *supposed* to be shorter than chunk_seconds)
  h  healthy: d covers c (within 3 s slop)

Entries older than 48 h (by filename timestamp) are dropped. The uploader
merges this cache into manifest.json.
"""
import json
import os
import re
import sys
import time

V1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
V2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
SR = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}
CHUNK_RE = re.compile(r"^chunk_(\d{8}T\d{6})Z\.mp3$")


def mp3_duration(path):
    data = open(path, "rb").read()
    i, n, total = 0, len(data), 0.0
    while i + 4 <= n:
        if data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0:
            ver = (data[i + 1] >> 3) & 3          # 3=MPEG1, 2=MPEG2, 0=MPEG2.5
            layer = (data[i + 1] >> 1) & 3        # 1=Layer III
            bri = (data[i + 2] >> 4) & 15
            sri = (data[i + 2] >> 2) & 3
            pad = (data[i + 2] >> 1) & 1
            if ver != 1 and layer == 1 and 0 < bri < 15 and sri < 3:
                sr = SR[ver][sri]
                br = (V1L3 if ver == 3 else V2L3)[bri] * 1000
                spf = 1152 if ver == 3 else 576
                flen = (spf // 8) * br // sr + pad
                if flen > 4:
                    total += spf / sr
                    i += flen
                    continue
        i += 1  # resync past garbage
    return total


def intended_coverage(name, chunk_seconds):
    m = CHUNK_RE.match(name)
    ts = m.group(1)  # YYYYMMDDTHHMMSS
    into_day = int(ts[9:11]) * 3600 + int(ts[11:13]) * 60 + int(ts[13:15])
    rem = into_day % chunk_seconds
    return chunk_seconds - rem if rem else chunk_seconds


def main():
    cache_path, chunk_dir = sys.argv[1], sys.argv[2]
    chunk_seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    try:
        cache = json.load(open(cache_path))
    except (OSError, ValueError):
        cache = {}
    cache = {k: v for k, v in cache.items() if isinstance(v, dict)}

    now = time.time()
    for name in os.listdir(chunk_dir):
        if not CHUNK_RE.match(name) or name in cache:
            continue
        path = os.path.join(chunk_dir, name)
        try:
            if now - os.path.getmtime(path) < 15:   # still being written
                continue
            d = round(mp3_duration(path), 1)
            c = intended_coverage(name, chunk_seconds)
            cache[name] = {"d": d, "c": c, "h": d >= c - 3}
        except OSError:
            pass

    horizon = time.strftime("chunk_%Y%m%dT%H%M%S", time.gmtime(now - 48 * 3600))
    cache = {k: v for k, v in cache.items() if k >= horizon}

    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, cache_path)


if __name__ == "__main__":
    main()
