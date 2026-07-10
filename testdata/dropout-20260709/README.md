# Dropout test sequence — 2026-07-09, 19:10–19:40 UTC

A real captured sequence spanning a period where 95bFM's Icecast server
repeatedly dropped TLS connections ("IO error: End of file" → ffmpeg
auto-reconnect). Useful for testing player handling of truncated and
off-grid chunks. The `.mp3` files are gitignored — this directory lives on
the NUC only; the chunks were copied out of R2 before the 36 h retention
pruned them.

| chunk | size | ~audio | notes |
|---|---|---|---|
| `chunk_20260709T191000Z` | 9.6 MB | 300 s | healthy, clock-aligned |
| `chunk_20260709T191505Z` | 7.9 MB | ~248 s | off-grid start (reconnect), truncated by next drop |
| `chunk_20260709T192000Z` | 3.9 MB | ~121 s | clock-aligned but truncated — the chunk behind the 2026-07-10 freeze bug |
| `chunk_20260709T192504Z` | 2.1 MB | ~65 s | off-grid and truncated |
| `chunk_20260709T193108Z` | 8.2 MB | ~256 s | off-grid recovery chunk |
| `chunk_20260709T193500Z` | 9.6 MB | 300 s | healthy again |

(~audio estimated as size ÷ 32 000 B/s; the stream is 256 kbps CBR MP3.)

To reproduce a player scenario: copy these into a bucket/prefix, generate a
manifest listing exactly these six names, and point the player at it with
`?delayMinutes=` chosen so `now − delay` lands at 19:24:00 UTC — the
original failure asked for 4 min into the 2-minute `192000Z` chunk.
