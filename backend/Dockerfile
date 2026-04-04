# build stage
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# install zig 0.16.0-dev
ARG ZIG_VERSION=0.16.0-dev.3059+42e33db9d
RUN curl -L https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz | tar -xJ -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseSafe

# runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

WORKDIR /app
COPY --from=builder /app/zig-out/bin/leaflet-search .

EXPOSE 3000

CMD ["./leaflet-search"]
