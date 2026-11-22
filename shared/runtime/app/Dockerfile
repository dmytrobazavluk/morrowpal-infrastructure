FROM ghcr.io/nginx/nginx-unprivileged:1.30.7-alpine3.24-slim@sha256:8432c57ac86f178741af2b89948bd9087cb9df1c415bc1ab4d23735c4f0e3e61

USER root

RUN apk upgrade --no-cache \
    && rm -f /etc/nginx/conf.d/default.conf

COPY --from=web --chown=101:101 . /usr/share/nginx/html/

# Deployment supplies this separately. Reject a local preview configuration.
RUN test ! -e /usr/share/nginx/html/runtime-config.js

USER 101:101

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:8080/ready || exit 1
