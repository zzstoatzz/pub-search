# build stage
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz | tar -xJ -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY scripts ./scripts
COPY src ./src

# pre-fetch deps with github fallback for tangled.* outages (tangled.sh flaked
# mid-build otherwise — same mitigation as the backend).
RUN ./scripts/fetch-deps.sh

# pin to x86_64_v3 (AVX2) — matches the backend; fly EPYC machines support it.
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3

# runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

WORKDIR /app
COPY --from=builder /app/zig-out/bin/leaflet-ingester .

CMD ["./leaflet-ingester"]
