#!/bin/bash
# Sync completed chunks to R2, prune past retention, keep manifest.json fresh.
# Uses the AWS CLI against R2's S3 endpoint. Runs forever (systemd restarts it
# if it dies); transient failures are logged and retried on the next pass.
# Set RUN_ONCE=1 to do a single pass and exit (testing / cron).
set -u

# systemd services get a minimal PATH that omits snap binaries (aws-cli)
export PATH="$PATH:/snap/bin"

ENV_FILE="${ENV_FILE:-/opt/radio-delay/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID must be set}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID must be set}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY must be set}"
: "${R2_BUCKET:?R2_BUCKET must be set}"
CHUNK_DIR="${CHUNK_DIR:-/opt/radio-delay/data/chunks}"
CHUNK_SECONDS="${CHUNK_SECONDS:-300}"
RETENTION_HOURS="${RETENTION_HOURS:-36}"
LOCAL_KEEP_HOURS="${LOCAL_KEEP_HOURS:-24}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# R2 predates the aws-cli v2.23 default integrity checksums; be compatible
# with any CLI version:
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
r2() { aws --endpoint-url "$ENDPOINT" "$@"; }

TMP_MANIFEST="$(mktemp /tmp/manifest.XXXXXX.json)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

log() { echo "$(date -u +%FT%TZ) $*" >&2; }

pass() {
    # 1. Upload finished chunks. Files modified in the last 15s are still
    #    being written by ffmpeg (mtime updates continuously), so skip them.
    local sync_args=(--exclude '*' --include 'chunk_*.mp3')
    local f
    while IFS= read -r f; do
        sync_args+=(--exclude "$f")
    done < <(find "$CHUNK_DIR" -name 'chunk_*.mp3' -newermt '-15 seconds' -printf '%f\n')
    r2 s3 sync "$CHUNK_DIR" "s3://${R2_BUCKET}/chunks" "${sync_args[@]}" --no-progress \
        || log "upload pass failed; will retry"

    # 2. Prune remote chunks past retention. Filenames encode UTC start time,
    #    so a lexicographic compare against the cutoff is a time compare.
    local cutoff key
    cutoff="chunks/chunk_$(date -u -d "${RETENTION_HOURS} hours ago" +%Y%m%dT%H%M%S)Z.mp3"
    while IFS= read -r key; do
        [[ "$key" == chunks/chunk_* && "$key" < "$cutoff" ]] || continue
        r2 s3 rm "s3://${R2_BUCKET}/${key}" --only-show-errors || log "prune failed: $key"
    done < <(r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix 'chunks/chunk_' \
                --query 'Contents[].Key' --output text | tr '\t' '\n')

    # 3. Prune local buffer.
    find "$CHUNK_DIR" -name 'chunk_*.mp3' -mmin +"$((LOCAL_KEEP_HOURS * 60))" -delete

    # 4. Regenerate manifest from what is actually in the bucket now.
    if r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix 'chunks/chunk_' \
            --query 'Contents[].Key' --output json \
        | CHUNK_SECONDS="$CHUNK_SECONDS" python3 -c '
import json, os, sys, time
keys = json.load(sys.stdin) or []
chunks = sorted(k.split("/", 1)[1] for k in keys if k.endswith(".mp3"))
print(json.dumps({
    "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "chunkSeconds": int(os.environ["CHUNK_SECONDS"]),
    "chunks": chunks,
}))' > "$TMP_MANIFEST" && [[ -s "$TMP_MANIFEST" ]]; then
        r2 s3 cp "$TMP_MANIFEST" "s3://${R2_BUCKET}/manifest.json" \
            --cache-control no-store --content-type application/json --only-show-errors \
            || log "manifest upload failed"
    else
        log "manifest build failed"
    fi
}

if [[ "${RUN_ONCE:-0}" == "1" ]]; then
    pass
    exit 0
fi

while true; do
    pass
    sleep "$SYNC_INTERVAL"
done
