# based on https://github.com/strowi/varnish/

FROM ubuntu:20.04
LABEL maintainer="Pavel Astakhov <pastakhov@yandex.ru>"

ENV LC_ALL=C \
    DEBIAN_FRONTEND=noninteractive \
    VARNISH_CONFIG=/etc/varnish/default.vcl \
    VARNISH_SECRET=/etc/varnish/secret \
    VARNISH_SIZE=100M \
    VARNISH_STORAGE_KIND=malloc \
    VARNISH_STORAGE_FILE=/data/cache.bin \
    LOG_FILES_COMPRESS_DELAY=3600 \
    LOG_FILES_REMOVE_OLDER_THAN_DAYS=10

ARG BUILD_DEPS=" \
      gnupg \
      ca-certificates \
      apt-transport-https \
      git \
      build-essential \
      libtool \
      make \
      automake \
      autotools-dev \
      pkg-config \
      python3-docutils"

ARG DUMB_INIT_VERSION="1.2.2"
ARG VARNISH_VERSION="7.0.*"
ARG VARNISH_MODULES_TAG=7.0
ARG VMOD_RE_VERSION=7.0
ARG VARNISH_EXPORTER_VERSION=1.6

RUN set -x; \
  apt-get update -qqy \
  && apt-get install -qqy --no-install-recommends \
    $BUILD_DEPS \
    netbase \
    iproute2 \
    iputils-ping \
    iputils-tracepath \
    traceroute \
    curl \
    netcat-openbsd \
    python3 \
  && curl -L -o /usr/local/bin/dumb-init https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_amd64 \
  && chmod +x /usr/local/bin/dumb-init \
  && curl -L https://packagecloud.io/varnishcache/varnish70/gpgkey | apt-key add - \
  && echo "deb https://packagecloud.io/varnishcache/varnish70/ubuntu/ focal main" > /etc/apt/sources.list.d/varnish.list \
  && echo "deb-src https://packagecloud.io/varnishcache/varnish70/ubuntu/ focal main " >> /etc/apt/sources.list.d/varnish.list \
  && apt-get update -qq \
  && apt-get install -qqy \
    varnish=${VARNISH_VERSION} \
    varnish-dev=${VARNISH_VERSION} \
  # install varnish-modules
  && cd /usr/src \
    && git clone --depth=1 --branch $VARNISH_MODULES_TAG https://github.com/varnish/varnish-modules.git \
    && cd varnish-modules \
    && ./bootstrap \
    && ./configure --prefix=/usr \
    && make -j4 \
    && make -j4 check \
    && make install \
  # + libvmod-re
#  &&  cd /usr/src \
#    && git clone --depth=1 --branch $VMOD_RE_VERSION https://code.uplex.de/uplex-varnish/libvmod-re.git \
#    && cd /usr/src/libvmod-re \
#    && ./autogen.sh \
#    && ./configure --disable-dependency-tracking \
#    && make -j4 \
#    && make -j4 check \
#    && make install \
  # + varnish-exporter
  && cd /usr/local/bin \
    && curl -sL https://github.com/jonnenauha/prometheus_varnish_exporter/releases/download/${VARNISH_EXPORTER_VERSION}/prometheus_varnish_exporter-${VARNISH_EXPORTER_VERSION}.linux-amd64.tar.gz \
      |tar xz --strip-components=1 \
  # && apt-get -y clean \
  && apt-get purge -y \
    $BUILD_DEPS \
    varnish-dev \
  && apt-get -y autoremove \
  && rm -fr \
    /usr/local/share/doc \
    /usr/local/share/man \
    /usr/src/* \
    /tmp/* \
    /var/lib/apt/* \
    /var/cache/* \
    /var/tmp/* \
    /var/log/*

# RUN ln -s "lg_dirty_mult:8,lg_chunk:18" /etc/malloc.conf

COPY docker-entrypoint.sh /
COPY varnish_reload_vcl.sh /usr/bin/varnish_reload_vcl
COPY varnishncsa_sighup.sh /usr/bin/varnishncsa_sighup
COPY import_logs_matomo.sh /usr/bin/import_logs_matomo
COPY compress_old_logs.sh /usr/bin/compress_old_logs

EXPOSE 80 9131

ENTRYPOINT ["/usr/local/bin/dumb-init", "--"]
CMD ["/docker-entrypoint.sh"]
