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
log_date=$(head -1 "${VARNISH_LOG_DIR}/access_log" | sed -r 's~.*\[([0-9]+)/([A-Z][a-z]+)/([0-9]+):[0-9]+:[0-9]+:[0-9]+.*~\1 \2 \3~' )
if [ -n "$log_date" ]; then
    log_date_seconds=$(date -u -d "$log_date" +%s)
else
    echo "Can't get date from the log file"
    exit 3
fi

if ((current_date_seconds - log_date_seconds > 86400 )); then
    varnish_log_file="access_log_$(date -u -d "$log_date" '+%Y%m%d')"
    mv "${VARNISH_LOG_DIR}/access_log" "${VARNISH_LOG_DIR}/${varnish_log_file}"

    pid=$(</var/run/varnishncsa.pid)
    kill -s SIGHUP "$pid"
else
    varnish_log_file="access_log"
fi

# Run logs parser using Python 3
python3 /var/www/html/misc/log-analytics/import_logs.py \
  --url="$MATOMO_URL" \
  --login="$MATOMO_USER" \
  --password="$MATOMO_PASSWORD" \
  --idsite=1 \
  --recorders=4 \
  "$VARNISH_LOG_DIR/$varnish_log_file"

if [ "$varnish_log_file" != "access_log" ]; then

    # wait random number of seconds before compressing to avoid to compress log files simultaneously (especially for wiki farms)
    if [ "$LOG_FILES_COMPRESS_DELAY" -eq 0 ]; then
        DELAY=0
    else
        DELAY=$RANDOM
        ((DELAY %= "$LOG_FILES_COMPRESS_DELAY"))
    fi
#    echo "Wait for $DELAY seconds before compressing ${varnish_log_file}"
#    sleep "$DELAY"

#    tar --gzip --create --remove-files --absolute-names --transform 's/.*\///g' --file "${VARNISH_LOG_DIR}/${varnish_log_file}.tar.gz" "${VARNISH_LOG_DIR}/${varnish_log_file}"
#    compress_exit_code=${?}
#    if [[ ${compress_exit_code} == 0 ]]; then
#        echo "File ${varnish_log_file} was compressed."
#    else
#        echo "Error compressing file ${varnish_log_file} (tar exit code: ${compress_exit_code})."
#    fi

    # remove old log files
    if [ -n "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" ] && [ "$LOG_FILES_REMOVE_OLDER_THAN_DAYS" != false ]; then
        find "${VARNISH_LOG_DIR}" -type f -mtime "+$LOG_FILES_REMOVE_OLDER_THAN_DAYS" -iname "$varnish_log_file*" ! -iname ".*" ! -iname "access_log" -exec rm -f {} \;
    fi

    compress_old_logs "$DELAY" "$varnish_log_file" &
fi
