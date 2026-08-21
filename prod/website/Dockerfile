FROM nginxinc/nginx-unprivileged:1.30.4-alpine3.24@sha256:44e36330f74d4f3a1d4e222acca9e23b401fb87811a7597024502bb759c4dd49

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=website --chown=101:101 index.html robots.txt sitemap.xml styles.css /usr/share/nginx/html/
COPY --from=website --chown=101:101 assets/ /usr/share/nginx/html/assets/

USER 101:101

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --spider http://127.0.0.1:8080/ready || exit 1
