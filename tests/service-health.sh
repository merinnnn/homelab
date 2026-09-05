#!/bin/bash
set -e

PIHOLE_IP="10.0.10.10"
DOCKER_IP="10.0.10.20"

echo "Running service health checks..."

# Check Pi-hole
curl -s -o /dev/null -w "%{http_code}" "http://$PIHOLE_IP/admin" | grep -qE "200|302" && echo "Pi-hole Web: OK" || echo "Pi-hole Web: FAIL"
dig @"$PIHOLE_IP" cloudflare.com +short > /dev/null && echo "Pi-hole DNS: OK" || echo "Pi-hole DNS: FAIL"

# Check Docker services
curl -s -o /dev/null -w "%{http_code}" "http://$DOCKER_IP:9000" | grep -qE "200|302" && echo "Portainer: OK" || echo "Portainer: FAIL"
curl -s -o /dev/null -w "%{http_code}" "http://$DOCKER_IP:3001" | grep -qE "200|302" && echo "Uptime Kuma: OK" || echo "Uptime Kuma: FAIL"

echo "Checks complete."