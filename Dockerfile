FROM archlinux:latest

# Enable extra-testing repo for XRT packages
RUN printf '\n[extra-testing]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf

# Install base packages, XRT, and NPU plugin
# NOTE: The host must have amdxdna loaded for NPU access at runtime.
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        base-devel \
        ca-certificates \
        curl \
        unzip \
        wget \
        pciutils \
        fish \
        jq \
        vim \
        git \
        cmake \
        ninja \
        rust \
        boost \
        ffmpeg \
        pkgconf \
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
    && pacman -Scc --noconfirm

# Clone and build lemonade from source
ARG LEMONADE_VERSION
RUN git clone https://github.com/lemonade-sdk/lemonade.git /opt/lemonade && \
    cd /opt/lemonade && \
    if [ -n "$LEMONADE_VERSION" ]; then git checkout "v${LEMONADE_VERSION}"; fi && \
    cmake --preset default && \
    cmake --build --preset default && \
    cmake --install build && \
    rm -rf /opt/lemonade

# Download latest llamacpp-rocm binary
ARG LLAMACPP_ROCM_VERSION
ARG LLAMACPP_ROCM_TARGET=gfx1151
RUN set -eux; \
    if [ -n "$LLAMACPP_ROCM_VERSION" ]; then \
        LLAMACPP_ROCM_TAG="$LLAMACPP_ROCM_VERSION"; \
    else \
        LLAMACPP_ROCM_RELEASE_URL="https://github.com/lemonade-sdk/llamacpp-rocm/releases/latest"; \
        LLAMACPP_ROCM_TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$LLAMACPP_ROCM_RELEASE_URL")"; \
        LLAMACPP_ROCM_TAG="${LLAMACPP_ROCM_TAG##*/}"; \
    fi; \
    LLAMACPP_ROCM_ASSET="llama-${LLAMACPP_ROCM_TAG}-ubuntu-rocm-${LLAMACPP_ROCM_TARGET}-x64.zip"; \
    curl -fsSL -o "/tmp/${LLAMACPP_ROCM_ASSET}" "https://github.com/lemonade-sdk/llamacpp-rocm/releases/download/${LLAMACPP_ROCM_TAG}/${LLAMACPP_ROCM_ASSET}"; \
    mkdir -p /opt/llamacpp-rocm; \
    unzip -q "/tmp/${LLAMACPP_ROCM_ASSET}" -d /opt/llamacpp-rocm; \
    rm -f "/tmp/${LLAMACPP_ROCM_ASSET}"; \
    chmod +x /opt/llamacpp-rocm/llama-server
ENV PATH="/opt/llamacpp-rocm:${PATH}"

# Clone and build FastFlowLM
ARG FLM_VERSION
RUN git clone --recursive https://github.com/FastFlowLM/FastFlowLM.git /opt/FastFlowLM && \
    cd /opt/FastFlowLM/src && \
    if [ -n "$FLM_VERSION" ]; then git checkout "v${FLM_VERSION}"; fi && \
    cmake --preset linux-default && \
    cmake --build build && \
    cmake --install build && \
    rm -rf /opt/FastFlowLM

# Configure fish and starship
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y && \
    mkdir -p ~/.config/fish && \
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

# Copy nputop.py and make it executable
COPY utils/nputop.py /opt/nputop.py
RUN chmod +x /opt/nputop.py && \
    ln -s /opt/nputop.py /usr/local/bin/nputop

# Update PCI IDs
RUN update-pciids

# Create HuggingFace cache directories
ENV HF_HOME=/huggingface \
    HF_HUB_CACHE=/huggingface/hub

RUN mkdir -p "${HF_HOME}" "${HF_HUB_CACHE}" 

# Queries the health endpoint and checks for "status": "ok"
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f -s http://localhost:${LEMONADE_PORT}/api/v1/health | jq -e '.status == "ok"' > /dev/null || exit 1

# Start the server and passes the max loaded models configuration\
CMD exec /opt/bin/lemond
