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
        vulkan-icd-loader \
        vulkan-radeon \
        xrt \
        xrt-plugin-amdxdna \
    && pacman -Scc --noconfirm

# Clone and build lemonade-server from source
ARG LEMONADE_VERSION
RUN git clone https://github.com/lemonade-sdk/lemonade.git /opt/lemonade && \
    cd /opt/lemonade && \
    # if [ -n "$LEMONADE_VERSION" ]; then git checkout "v${LEMONADE_VERSION}"; fi && \
    cmake --preset default && \
    cmake --build --preset default && \
    cmake --install build

# Clone and build FastFlowLM
RUN git clone --recursive https://github.com/FastFlowLM/FastFlowLM.git /opt/FastFlowLM && \
    cd /opt/FastFlowLM/src && \
    cmake --preset linux-default && \
    cmake --build build && \
    cmake --install build

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

# Update PCI IDs
RUN update-pciids

# Create HuggingFace cache directories
ENV HF_HOME=/huggingface \
    HF_HUB_CACHE=/huggingface/hub

RUN mkdir -p "${HF_HOME}" "${HF_HUB_CACHE}" 

# Queries the health endpoint and checks for "status": "ok"
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f -s http://localhost:${LEMONADE_PORT}/api/v1/health | jq -e '.status == "ok"' > /dev/null || exit 1

# Start the server and passes the max loaded models configuration
CMD exec lemonade-server serve
