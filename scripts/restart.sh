#!/usr/bin/env bash
cd "$(dirname "$0")"

# Path to your docker-compose.yml
COMPOSE_FILE_PATH="./docker-compose.yml"

# Function to restart containers
restart_containers() {
    echo "Stopping all containers..."
    docker-compose -f "$COMPOSE_FILE_PATH" down

    echo "Starting all containers..."
    docker-compose -f "$COMPOSE_FILE_PATH" up -d

    echo "Containers restarted successfully."
}

# Function to check container status
check_status() {
    echo "Checking container statuses..."
    docker-compose -f "$COMPOSE_FILE_PATH" ps
}

# Restart containers and check their status
restart_containers
check_status

echo "Restart process completed."
