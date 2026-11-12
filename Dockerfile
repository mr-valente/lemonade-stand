# Runtime system. The build stage starts from this too, so Lemonade is compiled
# against exactly the libraries it runs with.
FROM archlinux:latest AS base

# Install base packages, XRT, and NPU plugin
# NOTE: The host must have amdxdna loaded for NPU access at runtime.
# `pacman -Scc --noconfirm` takes the prompt's default answer (keep the cache),
# so the confirmation is piped in instead.
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        # Kept at runtime: vLLM/Triton JIT-compile native modules
        base-devel \
        ca-certificates \
        curl \
        unzip \
        wget \
        pciutils \
        fish \
        starship \
        jq \
        vim \
        git \
        ffmpeg \
        openssl \
        zlib \
        systemd \
        # For Stable Diffusion
        numactl \
        # Vulkan packages
        vulkan-icd-loader \
        vulkan-radeon \
        # NPU support packages
        xrt \
        xrt-plugin-amdxdna \
        # For the nputop utility
        python-textual \
        python-rich \
    && yes | pacman -Scc

FROM base AS build

# Build-only toolchain; none of it reaches the final image.
RUN pacman -S --noconfirm --needed \
        cmake \
        ninja \
        nodejs \
        npm \
        pkgconf \
        python

# Clone and build lemonade from source, staging the install under /staging.
# Lemonade installs to /opt and symlinks into /usr; both honour DESTDIR.
ARG LEMONADE_VERSION
RUN git clone --depth 1 ${LEMONADE_VERSION:+--branch "v${LEMONADE_VERSION}"} \
        https://github.com/lemonade-sdk/lemonade.git /src/lemonade && \
    cd /src/lemonade && \
    cmake --preset default -DBUILD_WEB_APP=ON && \
    cmake --build --preset default && \
    DESTDIR=/staging cmake --install build

# The Docker client only. Lemonade runs its container backends on the host's
# daemon through a mounted socket; the image carries no engine of its own.
# Podman must stay out of this image: Lemonade prefers it whenever it is on PATH.
FROM docker:29-cli AS docker-cli

FROM base

COPY --from=build /staging/ /
COPY --from=docker-cli /usr/local/bin/docker /opt/docker/bin/docker

# Configure fish and starship
RUN mkdir -p ~/.config/fish && \
    starship preset pure-preset -o ~/.config/starship.toml && \
    echo "starship init fish | source" >> ~/.config/fish/config.fish && \
    echo "function fish_greeting" >> ~/.config/fish/config.fish && \
    echo "    echo '🍋 Welcome to the Lemonade Stand!'" >> ~/.config/fish/config.fish && \
    echo "end" >> ~/.config/fish/config.fish && \
    chsh -s /usr/bin/fish

# Copy fish functions
COPY functions/ /root/.config/fish/functions/

# Copy fish completions
COPY completions/ /root/.config/fish/completions/

# Discover backend and ROCm tools when Fish starts and after backend installs.
COPY conf.d/ /root/.config/fish/conf.d/

# Copy the startup wrapper and utilities, then make them executable.
# `docker` resolves to the wrapper, which forwards LEMONADE_CONTAINER_ENV.
COPY entrypoint.sh /opt/bin/lemonade-entrypoint
COPY utils/nputop.py /opt/nputop.py
COPY utils/docker-wrapper.sh /usr/local/bin/docker
COPY utils/preflight.sh /usr/local/bin/preflight
RUN chmod +x /opt/bin/lemonade-entrypoint /opt/nputop.py \
        /usr/local/bin/docker /usr/local/bin/preflight && \
    ln -s /opt/nputop.py /usr/local/bin/nputop

# Update PCI IDs
RUN update-pciids

# Model storage. The hub cache is $HF_HOME/hub, so overriding HF_HOME alone
# moves it; container backends need it at the same path as on the host.
ENV HF_HOME=/huggingface \
    XDG_RUNTIME_DIR=/run/lemonade

RUN mkdir -p "${HF_HOME}/hub"

# Variables forwarded from this container to container backends, when set.
ENV LEMONADE_CONTAINER_ENV="GPU_MAX_HW_QUEUES"

# Queries the health endpoint and checks for "status": "ok"
# 13305 is Lemonade's default port when LEMONADE_PORT is unset.
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f -s http://localhost:${LEMONADE_PORT:-13305}/api/v1/health | jq -e '.status == "ok"' > /dev/null || exit 1

# Start the server.
ENTRYPOINT ["/opt/bin/lemonade-entrypoint"]
CMD ["/opt/bin/lemond", "/root/.cache/lemonade"]
