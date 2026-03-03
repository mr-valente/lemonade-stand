#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Default values
LEMONADE_VERSION=""
IMAGE_NAME="valentemath/lemonade-stand"
TAG_MOD=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --lemonade) LEMONADE_VERSION="$2"; shift ;;
        --tag-mod) TAG_MOD="$2"; shift ;;
        --tag-mod=*) TAG_MOD="${1#*=}" ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Build tag suffix from modifier
TAG_SUFFIX=""
if [[ -n "$TAG_MOD" ]]; then
    TAG_SUFFIX="-$TAG_MOD"
fi

TAG_LATEST="latest${TAG_SUFFIX}"
TAG_VERSION="${LEMONADE_VERSION}${TAG_SUFFIX}"

echo "Building Docker image with Lemonade version $LEMONADE_VERSION..."
sudo TAG_MOD="$TAG_MOD" docker compose build --build-arg LEMONADE_VERSION=$LEMONADE_VERSION

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
