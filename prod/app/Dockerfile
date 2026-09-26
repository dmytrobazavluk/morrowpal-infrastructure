FROM nginxinc/nginx-unprivileged:1.30.4-alpine3.24-slim@sha256:7bbe8940bc478e5618e6d4cfbeda406e5b4217cacc06faacd665aca5e468595e

USER root

RUN apk upgrade --no-cache

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web --chown=101:101 . /usr/share/nginx/html/

USER 101:101

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:8080/ready || exit 1
