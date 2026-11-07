FROM rust:1.98.1-slim-bookworm@sha256:dacc9e51f252243eb59d2fb4cb4ad8b0d3f607b6a82c398cf8a321e59ff778a7

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config clang libclang-dev lld cmake \
    libdbus-1-dev libfontconfig1-dev libfreetype6-dev \
    libx11-dev libx11-xcb-dev libxcb1-dev libxcb-composite0-dev \
    libxcb-randr0-dev libxcb-render0-dev libxcb-shape0-dev \
    libxcb-xfixes0-dev libxcb-xkb-dev libxkbcommon-dev libxkbcommon-x11-dev \
    libwayland-dev libvulkan-dev libasound2-dev \
    python3 git file binutils desktop-file-utils \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add clippy rustfmt
