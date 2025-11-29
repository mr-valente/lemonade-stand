#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Default values
LEMONADE_VERSION=""
# TODO: Update this to your actual registry/image name (e.g., username/lemonade-stand)
IMAGE_NAME="valentemath/lemonade-stand" 

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --lemonade) LEMONADE_VERSION="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Check if version is provided
if [ -z "$LEMONADE_VERSION" ]; then
    echo "Error: Lemonade version is required"
    echo "Usage: ./build.sh --lemonade <version>"
    echo "Example: ./build.sh --lemonade 9.0.3"
    exit 1
fi

# Validate version format (basic semver check)
if ! [[ $LEMONADE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Warning: Version '$LEMONADE_VERSION' doesn't follow semver format (x.y.z)"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Building Docker image with Lemonade version $LEMONADE_VERSION..."
# Build the 'lemonade' service, overriding the build arg
sudo docker compose build --build-arg LEMONADE_VERSION=$LEMONADE_VERSION

echo "Tagging images with version $LEMONADE_VERSION..."
sudo docker tag "$IMAGE_NAME:latest" "$IMAGE_NAME:$LEMONADE_VERSION"

echo "Pushing images to registry..."
# Push in parallel for efficiency using background processes
sudo docker push "$IMAGE_NAME:latest" &
sudo docker push "$IMAGE_NAME:$LEMONADE_VERSION" &

# Wait for all background jobs to complete
wait

echo "✓ Successfully built and pushed version $LEMONADE_VERSION"
echo "Images pushed:"
echo "  - $IMAGE_NAME:latest"
echo "  - $IMAGE_NAME:$LEMONADE_VERSION"
