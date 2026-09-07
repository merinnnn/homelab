#!/bin/bash
set -e

GATEWAY="10.0.10.1"
PIHOLE_IP="10.0.10.10"
DOCKER_IP="10.0.10.20"

echo "Running network connectivity tests..."

# Test basic connectivity
ping -c 1 -W 2 "$GATEWAY" > /dev/null && echo "Gateway: OK" || echo "Gateway: FAIL"
ping -c 1 -W 2 8.8.8.8 > /dev/null && echo "Internet: OK" || echo "Internet: FAIL"
ping -c 1 -W 2 "$PIHOLE_IP" > /dev/null && echo "Pi-hole VM: OK" || echo "Pi-hole VM: FAIL"
ping -c 1 -W 2 "$DOCKER_IP" > /dev/null && echo "Docker VM: OK" || echo "Docker VM: FAIL"

# Test DNS
nslookup google.com "$PIHOLE_IP" > /dev/null 2>&1 && echo "DNS Resolution: OK" || echo "DNS Resolution: FAIL"

# Test ports
nc -z -w 2 "$PIHOLE_IP" 53 && echo "Pi-hole DNS Port: OK" || echo "Pi-hole DNS Port: FAIL"
nc -z -w 2 "$DOCKER_IP" 9000 && echo "Portainer Port: OK" || echo "Portainer Port: FAIL"
nc -z -w 2 "$DOCKER_IP" 3001 && echo "Uptime Kuma Port: OK" || echo "Uptime Kuma Port: FAIL"

echo "Tests complete."