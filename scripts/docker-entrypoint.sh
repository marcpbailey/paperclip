#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# If the Docker socket is mounted, ensure the node user can reach it regardless of
# host GID variance (OrbStack uses GID 0; Linux docker typically uses a dedicated GID).
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
    EXISTING_GROUP=$(getent group "$DOCKER_SOCK_GID" | cut -d: -f1)
    if [ -n "$EXISTING_GROUP" ]; then
        # GID already owned by an existing group (e.g. root on OrbStack) — just join it
        usermod -aG "$EXISTING_GROUP" node
    else
        # No group owns this GID yet — create/remap the docker group
        if getent group docker > /dev/null 2>&1; then
            groupmod -g "$DOCKER_SOCK_GID" docker
        else
            groupadd -g "$DOCKER_SOCK_GID" docker
        fi
        usermod -aG docker node
    fi
fi

exec gosu node "$@"
