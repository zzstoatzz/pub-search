# build stage
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# install zig (stable 0.16.0 — dev tarballs at /builds/ rotate out and 404
# weeks later, the stable /download/X.Y.Z/ url is durable)
ARG ZIG_VERSION=0.16.0
RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz | tar -xJ -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY scripts ./scripts
COPY src ./src

# pre-fetch deps with github fallback for tangled.* outages. tangled is
# the source of truth but goes down occasionally; the github mirrors of
# our own libs (logfire-zig, zug, poolio) provide an escape hatch. zon
# hashes validate either source, so a mirror drift fails the build
# loudly rather than silently.
RUN ./scripts/fetch-deps.sh

# pin to x86_64_v3 (AVX2) — fly EPYC machines support up to that. without
# -Dtarget+-Dcpu, zig auto-detects from the depot builder's CPU, which may
# include newer instructions (AVX-512) that the runtime machine doesn't
# support → SIGILL on first instruction. v3 covers all current fly machines.
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3

# runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    sqlite3 \
    rclone \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

WORKDIR /app
COPY --from=builder /app/zig-out/bin/leaflet-search .

EXPOSE 3000

CMD ["./leaflet-search"]
