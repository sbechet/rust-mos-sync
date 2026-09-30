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
ENV CARGO_TARGET_MOS_A2_NONE_LINKER=/opt/llvm-mos/bin/mos-apple2-clang
ENV CARGO_TARGET_MOS_ATARI2600_3E_NONE_LINKER=/opt/llvm-mos/bin/mos-atari2600-3e-clang
ENV CARGO_TARGET_MOS_ATARI2600_4K_NONE_LINKER=/opt/llvm-mos/bin/mos-atari2600-4k-clang
ENV CARGO_TARGET_MOS_ATARI5200_SUPERCART_NONE_LINKER=/opt/llvm-mos/bin/mos-atari5200-supercart-clang
ENV CARGO_TARGET_MOS_ATARI8_CART_MEGACART_NONE_LINKER=/opt/llvm-mos/bin/mos-atari8-cart-megacart-clang
ENV CARGO_TARGET_MOS_ATARI8_CART_STD_NONE_LINKER=/opt/llvm-mos/bin/mos-atari8-cart-std-clang
ENV CARGO_TARGET_MOS_ATARI8_CART_XEGS_NONE_LINKER=/opt/llvm-mos/bin/mos-atari8-cart-xegs-clang
ENV CARGO_TARGET_MOS_C128_NONE_LINKER=/opt/llvm-mos/bin/mos-c128-clang
ENV CARGO_TARGET_MOS_CPM65_NONE_LINKER=/opt/llvm-mos/bin/mos-cpm65-clang
ENV CARGO_TARGET_MOS_CX16_NONE_LINKER=/opt/llvm-mos/bin/mos-cx16-clang
ENV CARGO_TARGET_MOS_DODO_NONE_LINKER=/opt/llvm-mos/bin/mos-dodo-clang
ENV CARGO_TARGET_MOS_EATER_NONE_LINKER=/opt/llvm-mos/bin/mos-eater-clang
ENV CARGO_TARGET_MOS_FDS_NONE_LINKER=/opt/llvm-mos/bin/mos-fds-clang
ENV CARGO_TARGET_MOS_GEOS_CBM_NONE_LINKER=/opt/llvm-mos/bin/mos-geos-cbm-clang
ENV CARGO_TARGET_MOS_LYNX_BLL_NONE_LINKER=/opt/llvm-mos/bin/mos-lynx-bll-clang
ENV CARGO_TARGET_MOS_MEGA65_NONE_LINKER=/opt/llvm-mos/bin/mos-mega65-clang
ENV CARGO_TARGET_MOS_NEO6502_NONE_LINKER=/opt/llvm-mos/bin/mos-neo6502-clang
ENV CARGO_TARGET_MOS_NES_ACTION53_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-action53-clang
ENV CARGO_TARGET_MOS_NES_CNROM_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-cnrom-clang
ENV CARGO_TARGET_MOS_NES_GTROM_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-gtrom-clang
ENV CARGO_TARGET_MOS_NES_MMC1_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-mmc1-clang
ENV CARGO_TARGET_MOS_NES_MMC3_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-mmc3-clang
ENV CARGO_TARGET_MOS_NES_UNROM_512_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-unrom-512-clang
ENV CARGO_TARGET_MOS_NES_UNROM_NONE_LINKER=/opt/llvm-mos/bin/mos-nes-unrom-clang
ENV CARGO_TARGET_MOS_OSI_C1P_NONE_LINKER=/opt/llvm-mos/bin/mos-osi-c1p-clang
ENV CARGO_TARGET_MOS_PCE_CD_NONE_LINKER=/opt/llvm-mos/bin/mos-pce-cd-clang
ENV CARGO_TARGET_MOS_PCE_NONE_LINKER=/opt/llvm-mos/bin/mos-pce-clang
ENV CARGO_TARGET_MOS_PET_NONE_LINKER=/opt/llvm-mos/bin/mos-pet-clang
ENV CARGO_TARGET_MOS_RP6502_NONE_LINKER=/opt/llvm-mos/bin/mos-rp6502-clang
ENV CARGO_TARGET_MOS_RPC8E_NONE_LINKER=/opt/llvm-mos/bin/mos-rpc8e-clang
ENV CARGO_TARGET_MOS_SUPERVISION_NONE_LINKER=/opt/llvm-mos/bin/mos-supervision-clang
ENV CARGO_TARGET_MOS_VIC20_NONE_LINKER=/opt/llvm-mos/bin/mos-vic20-clang

WORKDIR /src
CMD ["cargo", "--version"]
