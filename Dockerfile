# syntax=docker/dockerfile:1
FROM php-base AS common

WORKDIR /app

RUN apt-get update && \
    apt-get -y --no-install-recommends install \
        mailcap \
        libcap2-bin \
    && \
    apt-get clean

RUN set -eux; \
	mkdir -p \
		/app/public \
		/config/caddy \
		/data/caddy \
		/etc/caddy; \
	sed -i 's/php/frankenphp run/g' /usr/local/bin/docker-php-entrypoint; \
	echo '<?php phpinfo();' > /app/public/index.php

COPY --link caddy/frankenphp/Caddyfile /etc/caddy/Caddyfile
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

CMD ["--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
HEALTHCHECK CMD curl -f https://localhost/healthz || exit 1

# See https://caddyserver.com/docs/conventions#file-locations for details
ENV XDG_CONFIG_HOME /config
ENV XDG_DATA_HOME /data

EXPOSE 80
EXPOSE 443
EXPOSE 443/udp
EXPOSE 2019

LABEL org.opencontainers.image.title=FrankenPHP
LABEL org.opencontainers.image.description="The modern PHP app server"
LABEL org.opencontainers.image.url=https://frankenphp.dev
LABEL org.opencontainers.image.source=https://github.com/dunglas/frankenphp
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Kévin Dunglas"


FROM common AS builder

ARG FRANKENPHP_VERSION='dev'

COPY --from=golang-base /usr/local/go /usr/local/go

ENV PATH /usr/local/go/bin:$PATH

# This is required to link the FrankenPHP binary to the PHP binary
RUN apt-get update && \
    apt-get -y --no-install-recommends install \
    libargon2-dev \
    libcurl4-openssl-dev \
    libonig-dev \
    libreadline-dev \
    libsodium-dev \
    libsqlite3-dev \
    libssl-dev \
    libxml2-dev \
    zlib1g-dev \
    && \
    apt-get clean

WORKDIR /go/src/app

COPY --link go.mod go.sum ./
RUN go mod graph | awk '{if ($1 !~ "@") print $2}' | xargs go get

RUN mkdir caddy && cd caddy
COPY --link caddy/go.mod caddy/go.sum ./caddy/

RUN cd caddy && go mod graph | awk '{if ($1 !~ "@") print $2}' | xargs go get

COPY --link *.* ./
COPY --link caddy caddy
COPY --link C-Thread-Pool C-Thread-Pool
COPY --link internal internal
COPY --link testdata testdata

# todo: automate this?
# see https://github.com/docker-library/php/blob/master/8.2/bookworm/zts/Dockerfile#L57-L59 for PHP values
ENV CGO_LDFLAGS="-lssl -lcrypto -lreadline -largon2 -lcurl -lonig -lz $PHP_LDFLAGS" CGO_CFLAGS="-DFRANKENPHP_VERSION=$FRANKENPHP_VERSION $PHP_CFLAGS" CGO_CPPFLAGS=$PHP_CPPFLAGS

RUN cd caddy/frankenphp && \
    GOBIN=/usr/local/bin go install -ldflags "-X 'github.com/caddyserver/caddy/v2.CustomVersion=FrankenPHP $FRANKENPHP_VERSION PHP $PHP_VERSION Caddy'" && \
    setcap cap_net_bind_service=+ep /usr/local/bin/frankenphp && \
    cp Caddyfile /etc/caddy/Caddyfile && \
    frankenphp version


FROM common AS runner

ENV GODEBUG=cgocheck=0

COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
RUN setcap cap_net_bind_service=+ep /usr/local/bin/frankenphp && \
	frankenphp version
