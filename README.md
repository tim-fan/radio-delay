# NZ Radio Time-Shift

Continuously records 95bFM (Auckland) and replays it delayed by the
NZ↔local timezone offset, so NZ Monday 9am plays at *your* Monday 9am.

> **Note**: all repo contents — code, player, diagram, this README — were
> generated with Claude Fable 5.

![System diagram](diagram.svg)

Key design points:

- **Chunk filenames are UTC** (`chunk_20260708T041500Z.mp3`). All timezone
  math lives in the player, so NZ DST transitions never make names ambiguous.
- **Segments align to clock boundaries** (`-segment_atclocktime 1`), so chunk
  start times are predictable; the manifest handles gaps and restarts.
- **The player is manifest-driven**: it fetches `manifest.json`, picks the
  chunk covering `now − delay`, seeks into it, and preloads the next chunk
  for near-gapless playback. Delay = NZ UTC-offset − local UTC-offset,
  computed live via `Intl` (DST-correct on both ends).

## Repo layout

```
capture/Containerfile, capture.sh   ffmpeg capture container (podman)
upload/upload.sh                    sync → R2, prune, manifest (aws cli)
player/index.html                   static player, lives in the bucket
deploy/*.service                    systemd units for the NUC
.env.example                        copy to .env, never commit .env
```

## 1. Cloudflare setup (once)

1. Create an R2 bucket.
2. R2 → *Manage API Tokens* → create a token with **Object Read & Write**
   scoped to the bucket. Note the Access Key ID / Secret Access Key.
3. Bucket → *Settings* → *Custom Domains* → connect a subdomain of a domain
   that's on Cloudflare (e.g. `radio.example.com`). This makes the bucket
   publicly readable at that hostname — that's both the player URL and the
   audio origin (same origin, so no CORS config needed).

## 2. NUC setup

Prereqs: `podman`, `aws` CLI, `python3`.

```bash
sudo mkdir -p /opt/radio-delay/data/chunks
sudo cp -r capture upload deploy /opt/radio-delay/
cp .env.example /opt/radio-delay/.env   # then fill in the R2_* values
chmod 600 /opt/radio-delay/.env
chmod +x /opt/radio-delay/upload/upload.sh

# build the capture image — as root, because the systemd units are system
# units, and rootful podman has a separate image store from your user's
sudo podman build -t radio-capture:latest /opt/radio-delay/capture

# install + start services
sudo cp deploy/radio-capture.service deploy/radio-upload.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now radio-capture radio-upload
```

Check it's alive:

```bash
ls -la /opt/radio-delay/data/chunks/        # chunks appearing every 5 min
journalctl -u radio-capture -u radio-upload -f
```

## 3. Deploy the player

```bash
set -a; source /opt/radio-delay/.env; set +a
aws --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    s3 cp player/index.html "s3://${R2_BUCKET}/index.html" \
    --cache-control max-age=60 --content-type "text/html; charset=utf-8"
```

Then open `https://radio.example.com/`. Until ~19–21 h of archive exists the
player will say nothing is recorded yet for the target time — append
`?delayMinutes=2` to the URL to listen near-live and verify the pipeline.

## Operational notes

- **Retention**: `RETENTION_HOURS=36` (` .env`) comfortably covers the max
  ~21 h delay. The uploader prunes R2 itself (R2 lifecycle rules only do
  whole days), plus keeps `LOCAL_KEEP_HOURS` of local buffer.
- **Cost**: 256 kbps ≈ 2.8 GB/day → ~4.2 GB stored at 36 h. Inside R2's
  10 GB free tier; egress via custom domain is free. ~90 k class-A ops/month
  (uploads + once-a-minute manifest), free tier is 1 M.
- **If bandwidth/storage bites**: switch `STREAM_URL` to the 64 kbps AAC
  mount (`https://streams.95bfm.com/stream128`) — chunks become `.aac`
  (update the extension in `capture.sh`, `upload.sh`, and the player's
  `CHUNK_RE`). MP3 was chosen because every browser plays it natively.
- **Stream mounts** (from `https://streams.95bfm.com/status-json.xsl`):
  `/stream95` MP3 256k · `/stream128` AAC 64k · `/stream112` FLAC.
- **Gaps**: if the stream or NUC dies, chunks are simply missing; the player
  skips to the next available chunk. After a restart mid-window, the first
  chunk starts at connect time (not clock-aligned) — also handled by the
  manifest lookup.
