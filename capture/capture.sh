#!/bin/bash
# Continuously record STREAM_URL into fixed-length chunks named by their
# UTC start time. All timezone math happens in the player; filenames are
# always UTC so NZ DST transitions never make names ambiguous.
set -u

: "${STREAM_URL:?STREAM_URL must be set}"
CHUNK_DIR="${CHUNK_DIR:-/data/chunks}"
CHUNK_SECONDS="${CHUNK_SECONDS:-300}"

export TZ=UTC
mkdir -p "$CHUNK_DIR"

# exec so ffmpeg is PID 1 and receives SIGTERM directly (clean segment close
# on stop). Restarts after crashes/disconnects are systemd's job (Restart=always).
echo "starting capture of $STREAM_URL (${CHUNK_SECONDS}s chunks)" >&2
exec ffmpeg -hide_banner -loglevel warning -nostdin \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30 \
    -i "$STREAM_URL" \
    -map 0:a -c copy \
    -f segment \
    -segment_time "$CHUNK_SECONDS" \
    -segment_atclocktime 1 \
    -reset_timestamps 1 \
    -strftime 1 \
    "$CHUNK_DIR/chunk_%Y%m%dT%H%M%SZ.mp3"
