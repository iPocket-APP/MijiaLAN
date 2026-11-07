FROM debian:12-slim@sha256:c67e92c8099ba22853ab4cfda7cfb494d253d6012ca82dee98ba8976772af018

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 -o 10001 -g 10001 /data /keys

COPY --chmod=0755 mijia-rust /usr/local/bin/mijia-rust
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/mijialan-bridge/
COPY licenses /usr/share/doc/mijialan-bridge/licenses
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/mijia-rust"]
CMD ["serve"]
