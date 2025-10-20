### Varnish 7.0 Docker Image

Lightweight Ubuntu-based Varnish 7.0 image with:

- Prometheus exporter built-in (exposes metrics on 9131 when admin secret is present)
- Flexible storage backends (malloc or file)
- Access logging via varnishncsa with selectable formats
- Helper utilities for hot-reloading VCL and log management
- Optional Matomo log import helper

Image: `pastakhov/varnish:7.0`

---

### Quick start (docker-compose)

Use this service definition as a starting point. It includes common settings, metrics, and a cron sidecar example for running Matomo log imports.

```yaml
varnish:
    container_name: ${COMPOSE_PROJECT_NAME}_varnish # don't allow to scale the container
    image: pastakhov/varnish:7.0
    restart: unless-stopped
    networks:
        - default
        - traefik-public
    depends_on:
        - web
    tmpfs:
        - /var/lib/varnish:exec
    environment:
        - VARNISH_SIZE=5G
        - VARNISH_STORAGE_KIND=file
        - VARNISH_LOG_DIR=/var/log/varnish
        - VARNISH_LOG_FORMAT=X-Real-IP
        - MATOMO_USER=admin
        - MATOMO_PASSWORD=${MATOMO_PASSWORD?Variable MATOMO_PASSWORD not set}
    volumes:
        - ./_resources/varnish:/etc/varnish:ro
        - varnish_data:/data
        - ./_logs/varnish:/var/log/varnish
        - matomo_data:/var/www/html
    labels:
        # cron
        - cron.enabled=true
        # Every hour at the 59th minute
        - cron.import_logs_matomo.schedule=59 * * * *
        - cron.import_logs_matomo.command=import_logs_matomo

cron:
    container_name: ${COMPOSE_PROJECT_NAME}_cron # don't allow to scale the container
    image: ghcr.io/wikiteq/cron:20250709-2da693f
    restart: unless-stopped
    environment:
        - COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
    volumes:
        - /var/run/docker.sock:/var/run/docker.sock:ro
        - ./_logs/cron:/var/log/cron
```

Notes:

- The cron sidecar watches container labels and runs the specified command inside the labeled container according to the schedule. Ensure Docker socket is mounted read-only.
- `tmpfs: /var/lib/varnish:exec` is recommended for performance.

---

### Exposed ports

- 80: Varnish HTTP listener
- 9131: Prometheus metrics (`prometheus_varnish_exporter`) – enabled when `VARNISH_SECRET` exists

---

### Volumes and important paths

- `/etc/varnish` (ro): Provide your `default.vcl` and optional `secret`
- `/data`: Used when `VARNISH_STORAGE_KIND=file` (default file at `/data/cache.bin`)
- `/var/log/varnish`: If `VARNISH_LOG_DIR` is set, varnishncsa writes `access_log` here
- `/var/www/html`: Matomo installation directory (needed for `import_logs_matomo` helper)

---

### Environment variables

- `VARNISH_CONFIG` (default: `/etc/varnish/default.vcl`): Path to main VCL
- `VARNISH_SECRET` (default: `/etc/varnish/secret`): When present, admin interface is enabled on `127.0.0.1:6082` and metrics exporter starts
- `VARNISH_SIZE` (default: `100M`): Cache size, e.g. `5G`
- `VARNISH_STORAGE_KIND` (default: `malloc`): `malloc` or `file`
- `VARNISH_STORAGE_FILE` (default: `/data/cache.bin`): Cache file path used when `file` storage is selected
- `VARNISH_STORAGE_SPECIFICATION` (optional): Full `-s` value to override auto-generated one, e.g. `file,/data/cache.bin,5G`
- `VARNISH_LOG_DIR` (optional): Directory for access logs; enables `varnishncsa` background process writing `${VARNISH_LOG_DIR}/access_log`
- `VARNISH_LOG_FORMAT` (optional): One of `X-Forwarded-For`, `X-Real-IP`, or a custom `varnishncsa -F` format string. Defaults to a combined-like format
- `MATOMO_USER` (default: `admin`): Matomo user for the log importer
- `MATOMO_PASSWORD` (required for Matomo import): Can also be read from `/run/secrets/matomo_password`
- `MATOMO_URL` (default: `http://matomo`): Base URL for Matomo API used by importer
- `LOG_FILES_COMPRESS_DELAY` (default: `3600`): Upper bound for random delay (seconds) before compressing rotated logs; `0` disables delay
- `LOG_FILES_REMOVE_OLDER_THAN_DAYS` (default: `10`): Remove old processed log files matching the rotated name pattern after N days

Storage notes:

- When `VARNISH_STORAGE_KIND=file`, the entrypoint will `chown` `VARNISH_STORAGE_FILE` to user `vcache` and use `file,<path>,<size>`.
- Otherwise it uses `<kind>,<size>`.

Logging notes:

- If `VARNISH_LOG_DIR` is set, `varnishncsa` runs in the background and writes to `${VARNISH_LOG_DIR}/access_log`.
- `VARNISH_LOG_FORMAT=X-Forwarded-For` or `X-Real-IP` are conveniences for common proxy headers.

Metrics notes:

- Metrics are exposed on port 9131 via `prometheus_varnish_exporter` when `VARNISH_SECRET` exists (admin interface enabled). Scrape `http://<container>:9131/metrics`.

---

### Runtime behavior (entrypoint)

At container start:

1. Computes storage specification from `VARNISH_STORAGE_KIND`, `VARNISH_STORAGE_FILE`, and `VARNISH_SIZE` unless `VARNISH_STORAGE_SPECIFICATION` is provided
2. Optionally starts `varnishncsa` if `VARNISH_LOG_DIR` is set
3. Enables admin and starts `prometheus_varnish_exporter` if `VARNISH_SECRET` exists
4. Starts `varnishd` in the foreground (`-F`) for container health

---

### Helper commands inside the container

- `varnish_reload_vcl`: Hot-loads the VCL specified by `VARNISH_CONFIG` and activates it via `varnishadm`
- `varnishncsa_sighup`: Sends `SIGHUP` to `varnishncsa` to reopen the log file after rotation
- `import_logs_matomo`: Rotates yesterday's access log if needed, runs Matomo's Python importer, then compresses and cleans old logs
- `compress_old_logs [delay] [skip_file]`: Compresses old uncompressed log files in `VARNISH_LOG_DIR` (internal helper)

Examples:

```bash
docker exec -it <varnish_container> varnish_reload_vcl
docker exec -it <varnish_container> varnishncsa_sighup
docker exec -it <varnish_container> import_logs_matomo
```

Matomo import details:

- Uses Matomo's `misc/log-analytics/import_logs.py` from the mounted Matomo directory (`/var/www/html`).
- Imports into site ID `1` with `--recorders=4` by default.
- If the current `access_log` contains only yesterday's date, it is rotated to `access_log_YYYYMMDD` and `varnishncsa` is signaled to reopen the file.
- After import, a background job compresses old logs and removes rotated files older than `LOG_FILES_REMOVE_OLDER_THAN_DAYS`.

---

### Building locally

```bash
docker build -t pastakhov/varnish:7.0 .
```

Provide your VCL and (optionally) `secret` in a bind mount to `/etc/varnish`.
