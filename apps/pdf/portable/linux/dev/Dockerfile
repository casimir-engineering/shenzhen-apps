# Build toolchain for the GTK4 Linux frontend.
# Matches the host (Ubuntu 25.10, GTK 4.20, libadwaita 1.8) so binaries built
# here run natively on the host session:
#   docker build -t shenzhen-build portable/linux/dev
#   docker run --rm -v "$PWD:/work" -w /work shenzhen-build \
#     make -C portable linux-gtk4
FROM ubuntu:25.10
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang pkg-config make git ca-certificates \
    libgtk-4-dev libadwaita-1-dev libssl-dev \
    minisign \
    python3 file unzip zip \
    && rm -rf /var/lib/apt/lists/*
