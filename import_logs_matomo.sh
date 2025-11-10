#!/bin/bash

if [ -z "$VARNISH_LOG_DIR" ]; then
    echo 'The VARNISH_LOG_DIR variable is not defined'
    exit 1
fi

if [ -z "$MATOMO_PASSWORD" ] && [ -f /run/secrets/matomo_password ]; then
    MATOMO_PASSWORD=$(< /run/secrets/matomo_password)
fi

if [ -z "$MATOMO_PASSWORD" ]; then
    echo 'The MATOMO_PASSWORD variable is not defined'
    exit 2
fi

MATOMO_USER=${MATOMO_USER:-admin}
MATOMO_URL=${MATOMO_URL:-"http://matomo"}

current_date_seconds=$(date -u +%s)

# Check if access_log file exists
if [ ! -f "${VARNISH_LOG_DIR}/access_log" ]; then
    echo "Access log file missing, sending SIGHUP to varnish to restart logging"
    pid=$(</var/run/varnishncsa.pid 2>/dev/null)
    if [ -n "$pid" ]; then
        kill -s SIGHUP "$pid" 2>/dev/null
    fi
    exit 0
fi

log_date=$(head -1 "${VARNISH_LOG_DIR}/access_log" | sed -r 's~.*\[([0-9]+)/([A-Z][a-z]+)/([0-9]+):[0-9]+:[0-9]+:[0-9]+.*~\1 \2 \3~' )
if [ -n "$log_date" ]; then
    log_date_seconds=$(date -u -d "$log_date" +%s)
else
    echo "Can't get date from the log file"
    exit 3
fi

if (( current_date_seconds - log_date_seconds > 86400 )); then
    varnish_log_file="access_log_$(date -u -d "$log_date" '+%Y%m%d')"
    mv "${VARNISH_LOG_DIR}/access_log" "${VARNISH_LOG_DIR}/${varnish_log_file}"

    pid=$(</var/run/varnishncsa.pid)
    kill -s SIGHUP "$pid"
else
    varnish_log_file="access_log"
fi

# Run logs parser using Python 3 (capture output to analyze failures)
echo "Importing log file: $varnish_log_file"
IMPORT_TMP_OUTPUT=$(mktemp)
python3 /var/www/html/misc/log-analytics/import_logs.py \
  --url="$MATOMO_URL" \
  --login="$MATOMO_USER" \
  --password="$MATOMO_PASSWORD" \
  --idsite=1 \
  --recorders=4 \
  "$VARNISH_LOG_DIR/$varnish_log_file" 2>&1 | tee "$IMPORT_TMP_OUTPUT"

import_exit_code=${PIPESTATUS[0]}

# Treat exit code 0 as success for any file; rename only when not the live access_log
if [ "$import_exit_code" -eq 0 ]; then
    if [ "$varnish_log_file" != "access_log" ]; then
        echo "Import successful, renaming $varnish_log_file to ${varnish_log_file}_imported"
        mv "${VARNISH_LOG_DIR}/$varnish_log_file" "${VARNISH_LOG_DIR}/${varnish_log_file}_imported"
    else
        echo "Import successful for $varnish_log_file"
    fi
else
    if grep -qi "cannot automatically determine the log format" "$IMPORT_TMP_OUTPUT"; then
        if [ "$varnish_log_file" != "access_log" ]; then
            echo "Detected unrecognized log format. Marking $varnish_log_file as bad format."
            mv "${VARNISH_LOG_DIR}/$varnish_log_file" "${VARNISH_LOG_DIR}/${varnish_log_file}_bad_format"
        fi
    else
        echo "Import failed with exit code $import_exit_code for file $varnish_log_file"
        # Check if file contains only CONNECT requests
        if [ "$varnish_log_file" != "access_log" ] && [ -f "${VARNISH_LOG_DIR}/$varnish_log_file" ]; then
            non_connect_lines=$(grep -v -c "CONNECT" "${VARNISH_LOG_DIR}/$varnish_log_file" 2>/dev/null | tr -d '\n' || echo 0)
            if [ "$non_connect_lines" -eq 0 ] && [ -s "${VARNISH_LOG_DIR}/$varnish_log_file" ]; then
                echo "All lines in the log file are CONNECT requests that cannot be imported. Marking $varnish_log_file as bad format."
                mv "${VARNISH_LOG_DIR}/$varnish_log_file" "${VARNISH_LOG_DIR}/${varnish_log_file}_bad_format"
            fi
        fi
    fi
fi
rm -f "$IMPORT_TMP_OUTPUT"

# Process old not-yet-imported files with lock protection
LOCK_FILE="${VARNISH_LOG_DIR}/.import_lock"

# Check if lock file exists and if PID is still running
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "Another import process is running (PID: $lock_pid), skipping old file processing"
    else
        echo "Stale lock file found, removing and creating new lock"
        rm -f "$LOCK_FILE"
        echo $$ > "$LOCK_FILE"
    fi
else
    echo "Creating lock file for old file processing"
    echo $$ > "$LOCK_FILE"
fi

# Only process old files if we have the lock
if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE")" = "$$" ]; then
    echo "Processing old not-yet-imported files..."

    # Find not-yet-imported files
    echo "Searching for old files to process..."
    file_count=0

    while IFS= read -r -d '' old_file; do
        filename=$(basename "$old_file")
        echo "Processing old file: $filename"
        ((file_count++))

        # Import the old file (capture output to analyze failures)
        OLD_IMPORT_TMP_OUTPUT=$(mktemp)
        python3 /var/www/html/misc/log-analytics/import_logs.py \
          --url="$MATOMO_URL" \
          --login="$MATOMO_USER" \
          --password="$MATOMO_PASSWORD" \
          --idsite=1 \
          --recorders=4 \
          "$old_file" 2>&1 | tee "$OLD_IMPORT_TMP_OUTPUT"

        old_import_exit_code=${PIPESTATUS[0]}

        if [ "$old_import_exit_code" -eq 0 ]; then
            echo "Old file import successful, renaming $filename to ${filename}_imported"
            mv "$old_file" "${old_file}_imported"
        else
            if grep -qi "cannot automatically determine the log format" "$OLD_IMPORT_TMP_OUTPUT"; then
                echo "Detected unrecognized log format. Marking $filename as bad format and continuing."
                mv "$old_file" "${old_file}_bad_format"
            else
                echo "Old file import failed with exit code $old_import_exit_code for $filename"
                # Check if file contains only CONNECT requests
                if [ -f "$old_file" ]; then
                    non_connect_lines=$(grep -v -c "CONNECT" "$old_file" 2>/dev/null | tr -d '\n' || echo 0)
                    if [ "$non_connect_lines" -eq 0 ] && [ -s "$old_file" ]; then
                        echo "All lines in the log file are CONNECT requests that cannot be imported. Marking $filename as bad format and continuing."
                        mv "$old_file" "${old_file}_bad_format"
                        rm -f "$OLD_IMPORT_TMP_OUTPUT"
                        continue
                    fi
                fi
                echo "Stopping processing due to import failure"
                rm -f "$LOCK_FILE"
                rm -f "$OLD_IMPORT_TMP_OUTPUT"
                exit "$old_import_exit_code"
            fi
        fi
        rm -f "$OLD_IMPORT_TMP_OUTPUT"
    done < <(find "${VARNISH_LOG_DIR}" -type f -name "access_log_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]" ! -name "*_imported" ! -name "*_bad_format" ! -name "*.gz" ! -name "*.tar.gz" -print0)

    if [ "$file_count" -eq 0 ]; then
        echo "No old files found to process"
    else
        echo "All old files processed successfully"
    fi

    # Remove lock file
    rm -f "$LOCK_FILE"
    echo "Lock file removed"
else
    echo "Skipping old file processing (no lock acquired)"
fi

# Calculate delay for compression (moved outside if scope)
if [ "$LOG_FILES_COMPRESS_DELAY" -eq 0 ]; then
    DELAY=0
else
    DELAY=$RANDOM
    ((DELAY %= "$LOG_FILES_COMPRESS_DELAY"))
fi

# remove old archived log files (moved outside if scope)
if [ -n "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" ] && [ "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" != false ]; then
    # Validate that LOG_FILES_REMOVE_OLDER_THAN_DAYS is a positive integer
    if [[ "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" =~ ^[0-9]+$ ]] && [ "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" -gt 0 ]; then
        echo "Removing old archived log files older than $LOG_FILES_REMOVE_OLDER_THAN_DAYS days..."
        find "${VARNISH_LOG_DIR}" -type f -mtime "+$LOG_FILES_REMOVE_OLDER_THAN_DAYS" -iname "access_log_*.gz" -exec sh -c 'echo "Removing: $1"; rm -f "$1"' _ {} \;
    else
        if [ "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" = "false" ]; then
            echo "LOG_FILES_REMOVE_OLDER_THAN_DAYS is set to 'false', skipping old file removal"
        else
            echo "Warning: LOG_FILES_REMOVE_OLDER_THAN_DAYS must be a positive integer, got: '$LOG_FILES_REMOVE_OLDER_THAN_DAYS'. Skipping old file removal."
        fi
    fi
fi

# Check for any uncompressed *_imported or *_bad_format files before starting background compressor
if find "${VARNISH_LOG_DIR}" -type f \( -name "*_imported" -o -name "*_bad_format" \) ! -name "*.gz" ! -name "*.tar.gz" -print -quit | grep -q .; then
    echo "Found files to compress; scheduling background compression with delay: $DELAY seconds..."
    # Use nohup to ignore SIGHUP from cron, and redirect to container logs
    nohup compress_old_logs "$DELAY" >> /proc/1/fd/1 2>> /proc/1/fd/2 &
else
    echo "No files to compress; skipping background compression"
fi
