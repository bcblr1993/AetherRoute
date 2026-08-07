FROM nginx:1.28.3-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236

STOPSIGNAL SIGTERM

RUN addgroup -S -g 12000 aetherroute-service \
    && adduser -S -D -H -u 10001 -G aetherroute-service aetherroute-signer \
    && adduser -S -D -H -u 10002 -G aetherroute-service aetherroute-web

COPY aetherroute-distribution /usr/local/bin/aetherroute-distribution
COPY signer-entrypoint.sh /usr/local/bin/aetherroute-signer-entrypoint
COPY web-entrypoint.sh /usr/local/bin/aetherroute-web-entrypoint
COPY nginx.conf /etc/nginx/nginx.conf

USER 10002:12000
ENTRYPOINT ["/bin/setpriv", "--no-new-privs", "/usr/local/bin/aetherroute-web-entrypoint"]
