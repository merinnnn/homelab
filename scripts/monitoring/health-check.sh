#!/bin/bash
set -e

PIHOLE_IP="10.0.10.10"
DOCKER_IP="10.0.10.20"

echo "Running homelab health check..."

# Network
ping -c 1 -W 2 8.8.8.8 > /dev/null && echo "Internet: OK" || echo "Internet: FAIL"

# Services
curl -s -o /dev/null -w "%{http_code}" "http://$PIHOLE_IP/admin" | grep -qE "200|302" && echo "Pi-hole: OK" || echo "Pi-hole: FAIL"
curl -s -o /dev/null -w "%{http_code}" "http://$DOCKER_IP:9000" | grep -qE "200|302" && echo "Portainer: OK" || echo "Portainer: FAIL"
curl -s -o /dev/null -w "%{http_code}" "http://$DOCKER_IP:3001" | grep -qE "200|302" && echo "Uptime Kuma: OK" || echo "Uptime Kuma: FAIL"

echo "Health check complete."