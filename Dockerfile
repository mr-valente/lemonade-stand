FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        libcurl4 \
        libatomic1 \
        wget \
        pciutils \
        fish \
        jq \
        vim \
    && rm -rf /var/lib/apt/lists/*

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

# Configuration
ARG LEMONADE_VERSION
ENV LEMONADE_HOST=0.0.0.0 \
    LEMONADE_PORT=8000 \
    LEMONADE_MAX_LOADED_MODELS="1 1 1" \
    LEMONADE_LLAMACPP=rocm

# Download and install lemonade-server
RUN set -eux; \
    wget "https://github.com/lemonade-sdk/lemonade/releases/download/v${LEMONADE_VERSION}/lemonade-server-minimal_${LEMONADE_VERSION}_amd64.deb"; \
    dpkg -i "lemonade-server-minimal_${LEMONADE_VERSION}_amd64.deb"; \
    rm "lemonade-server-minimal_${LEMONADE_VERSION}_amd64.deb"

# Create HuggingFace cache directories
ENV HF_HOME=/huggingface \
    HF_HUB_CACHE=/huggingface/hub

RUN mkdir -p "${HF_HOME}" "${HF_HUB_CACHE}" 

# Queries the health endpoint and checks for "status": "ok"
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f -s http://localhost:${LEMONADE_PORT}/api/v1/health | jq -e '.status == "ok"' > /dev/null || exit 1

# Start the server and passes the max loaded models configuration
CMD exec lemonade-server serve --max-loaded-models $LEMONADE_MAX_LOADED_MODELS
