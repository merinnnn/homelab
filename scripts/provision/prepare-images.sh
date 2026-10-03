#!/usr/bin/env bash
set -euo pipefail

DEBIAN_RELEASE="13"
DEBIAN_CODENAME="trixie"
ARCH="$(dpkg --print-architecture)"

CLOUD_IMAGE="debian-${DEBIAN_RELEASE}-genericcloud-${ARCH}.qcow2"
CLOUD_BASE="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/latest"

# Discover storage
TEMPLATE_STORAGE="$(
    pvesm status -content vztmpl |
    awk 'NR > 1 && $3 == "active" {print $1; exit}'
)"

IMPORT_STORAGE="$(
    pvesm status -content import |
    awk 'NR > 1 && $3 == "active" {print $1; exit}'
)"

[ -n "$TEMPLATE_STORAGE" ] || {
    echo "No active LXC template storage found"
    exit 1
}

[ -n "$IMPORT_STORAGE" ] || {
    echo "No active import storage found"
    exit 1
}

# LXC template
pveam update

TEMPLATE="$(
    pveam available --section system |
    awk -v release="$DEBIAN_RELEASE" -v arch="$ARCH" \
        '$2 ~ "^debian-" release "-standard_" && $3 == arch {print $2}' |
    sort -V |
    tail -1
)"

[ -n "$TEMPLATE" ] || {
    echo "No Debian $DEBIAN_RELEASE $ARCH LXC template found"
    exit 1
}

if ! pveam list "$TEMPLATE_STORAGE" |
    awk 'NR > 1 {print $1}' |
    grep -Fqx "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"; then
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# Cloud image
IMPORT_PATH="$(pvesm path "${IMPORT_STORAGE}:import/${CLOUD_IMAGE}")"
TMP_IMAGE="${IMPORT_PATH}.download"
TMP_SUMS="${IMPORT_PATH}.SHA512SUMS"

mkdir -p "$(dirname "$IMPORT_PATH")"

curl -fsSL "$CLOUD_BASE/SHA512SUMS" -o "$TMP_SUMS"

EXPECTED_SUM="$(
    grep " $CLOUD_IMAGE\$" "$TMP_SUMS" |
    awk '{print $1}'
)"

[ -n "$EXPECTED_SUM" ] || {
    rm -f "$TMP_SUMS"
    echo "No checksum found for $CLOUD_IMAGE"
    exit 1
}

CURRENT_SUM=""

if [ -f "$IMPORT_PATH" ]; then
    CURRENT_SUM="$(
        sha512sum "$IMPORT_PATH" |
        awk '{print $1}'
    )"
fi

if [ "$CURRENT_SUM" != "$EXPECTED_SUM" ]; then
    rm -f "$TMP_IMAGE"

    curl -fL --progress-bar \
        "$CLOUD_BASE/$CLOUD_IMAGE" \
        -o "$TMP_IMAGE"

    echo "$EXPECTED_SUM  $TMP_IMAGE" |
        sha512sum --check -

    mv "$TMP_IMAGE" "$IMPORT_PATH"
fi

rm -f "$TMP_SUMS"

# Final state
echo "--- LXC TEMPLATE ---"
pveam list "$TEMPLATE_STORAGE" |
    awk 'NR > 1 {print $1}' |
    grep -Fqx "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

echo "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

echo "--- CLOUD IMAGE ---"
pvesm list "$IMPORT_STORAGE" --content import |
    grep "$CLOUD_IMAGE"

echo "Images prepared."