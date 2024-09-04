#!/bin/bash

DELAY=${1:0}

if (( DELAY > 0 )); then
    echo "Wait for $DELAY seconds before compressing old log files"
    sleep "$DELAY"
fi

varnish_log_file=${2:-}

# compress uncompressed old log files
find "${VARNISH_LOG_DIR}" -type f -mtime "+2" ! -iname "$varnish_log_file" ! -iname ".*" ! -iname "access_log" ! -iname "*.gz" ! -iname "*.zip" -exec tar --gzip --create --remove-files --absolute-names --transform 's/.*\///g' --file {}.tar.gz {} \;
