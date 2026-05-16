#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

LATEST_LEMONADE_RELEASE_URL="https://github.com/lemonade-sdk/lemonade/releases/latest"
LATEST_FLM_RELEASE_URL="https://github.com/FastFlowLM/FastFlowLM/releases/latest"

# Default values
LEMONADE_VERSION=""
FLM_VERSION=""
IMAGE_NAME="valentemath/lemonade-stand"
TAG_MOD=""

normalize_version() {
    local version="$1"
    echo "${version#v}"
}

resolve_latest_release_version() {
    local release_url="$1"
    local component_name="$2"
    local resolved_url
    local tag_name

    resolved_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$release_url") || {
        echo "Failed to resolve latest $component_name release from $release_url" >&2
        exit 1
    }

    tag_name="${resolved_url##*/}"

    if [[ -z "$tag_name" || "$tag_name" == "latest" ]]; then
        echo "Failed to parse latest $component_name release tag from $resolved_url" >&2
        exit 1
    fi

    normalize_version "$tag_name"
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --lemonade)
            if [[ -n "$2" && "$2" != --* ]]; then
                LEMONADE_VERSION="$2"
                shift
            fi
            ;;
        --lemonade=*) LEMONADE_VERSION="${1#*=}" ;;
        --flm)
            if [[ -n "$2" && "$2" != --* ]]; then
                FLM_VERSION="$2"
                shift
            fi
            ;;
        --flm=*) FLM_VERSION="${1#*=}" ;;
        --tag-mod) TAG_MOD="$2"; shift ;;
        --tag-mod=*) TAG_MOD="${1#*=}" ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ -n "$LEMONADE_VERSION" ]]; then
    LEMONADE_VERSION=$(normalize_version "$LEMONADE_VERSION")
else
    LEMONADE_VERSION=$(resolve_latest_release_version "$LATEST_LEMONADE_RELEASE_URL" "Lemonade")
fi

if [[ -n "$FLM_VERSION" ]]; then
    FLM_VERSION=$(normalize_version "$FLM_VERSION")
else
    FLM_VERSION=$(resolve_latest_release_version "$LATEST_FLM_RELEASE_URL" "FastFlowLM")
fi

# Build tag suffix from modifier
TAG_SUFFIX=""
if [[ -n "$TAG_MOD" ]]; then
    TAG_SUFFIX="-$TAG_MOD"
fi

TAG_LATEST="latest${TAG_SUFFIX}"
TAG_VERSION="${LEMONADE_VERSION}${TAG_SUFFIX}"

echo "Building Docker image with Lemonade version $LEMONADE_VERSION and FastFlowLM version $FLM_VERSION..."
sudo TAG_MOD="$TAG_MOD" docker compose build --build-arg LEMONADE_VERSION="$LEMONADE_VERSION" --build-arg FLM_VERSION="$FLM_VERSION"

echo "Tagging images with version $TAG_VERSION..."
sudo docker tag "$IMAGE_NAME:$TAG_LATEST" "$IMAGE_NAME:$TAG_VERSION"

echo "Pushing images to registry..."
sudo docker push "$IMAGE_NAME:$TAG_LATEST" &
sudo docker push "$IMAGE_NAME:$TAG_VERSION" &

wait

echo "✓ Successfully built and pushed version $TAG_VERSION"
echo "Images pushed:"
echo "  - $IMAGE_NAME:$TAG_LATEST"
echo "  - $IMAGE_NAME:$TAG_VERSION"
echo "Resolved component versions:"
echo "  - Lemonade: $LEMONADE_VERSION"
echo "  - FastFlowLM: $FLM_VERSION"
