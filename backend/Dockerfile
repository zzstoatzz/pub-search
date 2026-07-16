# build stage
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# install zig (stable 0.16.0 — dev tarballs at /builds/ rotate out and 404
# weeks later, the stable /download/X.Y.Z/ url is durable)
ARG ZIG_VERSION=0.16.0
RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz | tar -xJ -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

# Debian bookworm ships an old development build. Pin a current release so R2
# behavior is reproducible and security updates do not depend on apt cadence.
ARG RCLONE_VERSION=1.74.4
ARG RCLONE_SHA256=fe435e0c36228e7c2f116a8701f01127bb1f694005fc11d1f27186c8bca4115d
RUN curl -fsSL "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" -o /tmp/rclone.zip \
    && echo "${RCLONE_SHA256}  /tmp/rclone.zip" | sha256sum -c - \
    && unzip -q /tmp/rclone.zip -d /tmp \
    && install -m 0755 "/tmp/rclone-v${RCLONE_VERSION}-linux-amd64/rclone" /usr/local/bin/rclone \
    && rm -rf /tmp/rclone.zip "/tmp/rclone-v${RCLONE_VERSION}-linux-amd64"

WORKDIR /app
# shared single source of truth, staged into the build context by CI (it lives
# at the repo root, outside this dir's context). build.zig embeds it via
# ../banned-dids.txt, which resolves to /banned-dids.txt from WORKDIR /app.
COPY banned-dids.txt /banned-dids.txt
COPY kept-dids.txt /kept-dids.txt
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
    && rm -rf /var/lib/apt/lists/* \
    && echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

WORKDIR /app
COPY --from=builder /app/zig-out/bin/pub-search .
COPY --from=builder /usr/local/bin/rclone /usr/local/bin/rclone

EXPOSE 3000

CMD ["./pub-search"]
