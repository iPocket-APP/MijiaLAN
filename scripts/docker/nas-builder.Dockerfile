FROM rust:1.98.1-slim-bookworm@sha256:dacc9e51f252243eb59d2fb4cb4ad8b0d3f607b6a82c398cf8a321e59ff778a7

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential musl-tools curl ca-certificates git python3 binutils librsvg2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add x86_64-unknown-linux-musl
ENV CC_x86_64_unknown_linux_musl=musl-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc
