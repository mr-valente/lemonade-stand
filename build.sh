#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Default values
LEMONADE_VERSION=""
IMAGE_NAME="valentemath/lemonade-stand" 

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --lemonade) LEMONADE_VERSION="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

echo "Building Docker image with Lemonade version $LEMONADE_VERSION..."
sudo docker compose build --build-arg LEMONADE_VERSION=$LEMONADE_VERSION

echo "Tagging images with version $LEMONADE_VERSION..."
sudo docker tag "$IMAGE_NAME:latest" "$IMAGE_NAME:$LEMONADE_VERSION"

echo "Pushing images to registry..."
sudo docker push "$IMAGE_NAME:latest" &
sudo docker push "$IMAGE_NAME:$LEMONADE_VERSION" &

wait

echo "✓ Successfully built and pushed version $LEMONADE_VERSION"
echo "Images pushed:"
echo "  - $IMAGE_NAME:latest"
echo "  - $IMAGE_NAME:$LEMONADE_VERSION"
