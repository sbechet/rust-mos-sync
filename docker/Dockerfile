# Ready-to-use Rust toolchain for the MOS 6502 family (llvm-mos backend).
# Built by .github/workflows/build.yml (job `docker`) from:
#   - the toolchain tarball dist.sh just produced in the same CI run
#     (rustc, cargo, host rust-std, MOS rust-std for every built-in target);
#   - the llvm-mos SDK release pinned in versions.toml (linkers, C runtime,
#     mos-sim), downloaded fresh, never rebuilt from source here.
# No compilation happens in this image build (PLAN.md §7.5, "no compilation
# in the image build" — docs/git-and-distribution.md §2.2).
#
# Usage:
#   docker run --rm -v "$PWD":/src ghcr.io/<owner>/rust-mos:stable \
#       cargo build --release --target mos-c64-none
# No .cargo/config.toml needed: the linker for every built-in MOS target is
# already set via CARGO_TARGET_*_LINKER below.

FROM debian:trixie-slim AS fetch
ARG SDK_RELEASE
ARG SDK_SHA256
RUN apt-get update -q \
    && apt-get install -yq --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL --retry 3 -o /tmp/sdk.tar.xz \
        "https://github.com/llvm-mos/llvm-mos-sdk/releases/download/${SDK_RELEASE}/llvm-mos-linux.tar.xz" \
    && echo "${SDK_SHA256}  /tmp/sdk.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/llvm-mos \
    && tar -xJf /tmp/sdk.tar.xz -C /opt/llvm-mos --strip-components=1 \
    && rm /tmp/sdk.tar.xz

# The dist.sh tarball for this run; placed in the build context by the
# workflow (downloaded from its own `toolchain-*` artifact).
COPY toolchain.tar.xz /tmp/toolchain.tar.xz
RUN mkdir -p /opt/rust-mos \
    && tar -xJf /tmp/toolchain.tar.xz -C /opt/rust-mos \
    && rm /tmp/toolchain.tar.xz

FROM debian:trixie-slim
LABEL org.opencontainers.image.source="https://github.com/sbechet/rust-mos-sync"
LABEL org.opencontainers.image.description="Rust toolchain for the MOS 6502 family (llvm-mos backend): core/alloc only, no std"
LABEL org.opencontainers.image.licenses="MIT OR Apache-2.0"

# libstdc++6/zlib1g: runtime deps of the LLVM-based SDK tools (clang, lld,
# mos-sim). ca-certificates: cargo needs it to reach crates.io.
RUN apt-get update -q \
    && apt-get install -yq --no-install-recommends ca-certificates libstdc++6 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /opt/llvm-mos /opt/llvm-mos
COPY --from=fetch /opt/rust-mos /opt/rust-mos

ENV PATH="/opt/rust-mos/bin:/opt/llvm-mos/bin:${PATH}"
# One linker per built-in target (compiler/rustc_target/src/spec/mod.rs);
# add a line here whenever a new MOS target is added there.
ENV CARGO_TARGET_MOS_UNKNOWN_NONE_LINKER=/opt/llvm-mos/bin/mos-clang
ENV CARGO_TARGET_MOS_SIM_NONE_LINKER=/opt/llvm-mos/bin/mos-sim-clang
ENV CARGO_TARGET_MOS_C64_NONE_LINKER=/opt/llvm-mos/bin/mos-c64-clang
ENV CARGO_TARGET_MOS_NES_NROM_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-nrom-clang
ENV CARGO_TARGET_MOS_ATARI8_DOS_NONE_LINKER=/opt/llvm-mos/bin/mos-atari8-dos-clang

WORKDIR /src
CMD ["cargo", "--version"]
