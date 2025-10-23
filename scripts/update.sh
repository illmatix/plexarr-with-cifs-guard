#!/usr/bin/env bash
cd "$(dirname "$0")"

# Define the services you want to update
services=("vpn" "qbittorrent" "jackett" "sonarr" "radarr" "plex")

# Pull the latest images for the services
echo "Pulling latest Docker images..."
for service in "${services[@]}"; do
    echo "Pulling image for $service..."
    docker compose pull $service
done

# Stop and remove the existing containers
echo "Stopping and removing existing containers..."
docker compose down

# Bring up the updated services
echo "Starting updated services..."
docker compose up -d

# Cleanup unused images, volumes, and networks
echo "Cleaning up unused Docker resources..."
docker system prune -f

echo "All services have been updated and are running."
