#!/bin/bash

DELAY=${1:-0}
LOCK_FILE="${VARNISH_LOG_DIR}/.compress_lock"

echo "Starting compress_old_logs script with delay: $DELAY"

# Check if lock file exists and if PID is still running
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "Another compression process is running (PID: $lock_pid), exiting"
        exit 0
    else
        echo "Stale lock file found, removing and creating new lock"
        rm -f "$LOCK_FILE"
    fi
fi

# Check if any _imported files exist before delay
echo "Checking for _imported files to compress..."
imported_files=$(find "${VARNISH_LOG_DIR}" -type f -name "*_imported" ! -name "*.gz" ! -name "*.tar.gz" 2>/dev/null)

if [ -z "$imported_files" ]; then
    echo "No _imported files found, exiting immediately"
    exit 0
fi

# Create lock file only if there are files to process
echo $$ > "$LOCK_FILE"
echo "Created compression lock file (PID: $$)"

echo "Found _imported files to compress: $(echo "$imported_files" | wc -l) files"

if (( DELAY > 0 )); then
    echo "Waiting for $DELAY seconds before compressing _imported files"
    sleep "$DELAY"
fi

echo "Starting compression of _imported files..."

# Find all uncompressed _imported files (no age filter)
find "${VARNISH_LOG_DIR}" -type f -name "*_imported" ! -name "*.gz" -print0 | while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    # Remove _imported from filename for compressed name
    compressed_name="${filename%_imported}.gz"
    compressed_path="${VARNISH_LOG_DIR}/${compressed_name}"

    echo "Compressing $filename -> $compressed_name"

    # Compress file directly with gzip, removing _imported from filename
    gzip -c "$file" > "$compressed_path" && rm -f "$file"

    compress_exit_code=$?
    if [ "$compress_exit_code" -eq 0 ]; then
        echo "Successfully compressed $filename -> $compressed_name"
    else
        echo "Error compressing $filename (gzip exit code: $compress_exit_code)"
    fi
done

echo "Compression process completed"

# Clean up lock file
rm -f "$LOCK_FILE"
echo "Compression lock file removed"

exit 0
