FROM ghcr.io/nginx/nginx-unprivileged:1.30.6-alpine3.24-slim@sha256:e333a5b95605942b5e495645ee54fab02b112081de6dbe45d2ead3ef38e03e31

USER root

RUN apk upgrade --no-cache \
    && rm -f /etc/nginx/conf.d/default.conf

COPY --from=web --chown=101:101 . /usr/share/nginx/html/

USER 101:101

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:8080/ready || exit 1
