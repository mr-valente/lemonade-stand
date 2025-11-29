FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        unzip \
        libcurl4 \
        libatomic1 \
        # libnuma1: Required by ROCm runtime for memory topology detection
        # libnuma1 \
        wget \
        pciutils \
    && rm -rf /var/lib/apt/lists/*

# Update PCI IDs
RUN update-pciids

# Configuration
ARG LEMONADE_VERSION
ENV LEMONADE_HOST=0.0.0.0

# Download and install lemonade-server
RUN set -eux; \
    wget "https://github.com/lemonade-sdk/lemonade/releases/download/v${LEMONADE_VERSION}/lemonade-server-minimal_${LEMONADE_VERSION}_amd64.deb"; \
    dpkg -i "lemonade-server-minimal_${LEMONADE_VERSION}_amd64.deb"; \
    rm "lemonade-server-minimal_${LEMONADE_VERSION}_amd64.deb"

# Create HuggingFace cache directories
ENV HF_HOME=/huggingface \
    HF_HUB_CACHE=/huggingface/hub

RUN mkdir -p "${HF_HOME}" "${HF_HUB_CACHE}" 

CMD ["lemonade-server", "serve"]
