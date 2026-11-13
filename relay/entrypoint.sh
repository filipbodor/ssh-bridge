#!/bin/sh
set -eu
umask 077
: "${RELAY_HOST_KEY_B64:?Missing relay host key}"
: "${DEVICE_PUBLIC_KEY:?Missing laptop public key}"
: "${CLIENT_PUBLIC_KEY:?Missing Mac public key}"
mkdir -p /run/ssh-bridge /etc/ssh/ssh-bridge-keys
printf '%s' "$RELAY_HOST_KEY_B64" | base64 -d > /run/ssh-bridge/host_ed25519
chmod 600 /run/ssh-bridge/host_ed25519
for role in device client; do
    if [ "$role" = device ]; then key="$DEVICE_PUBLIC_KEY"; else key="$CLIENT_PUBLIC_KEY"; fi
    # Accept one Ed25519 public key, never additional authorized_keys options.
    if ! printf '%s\n' "$key" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$'; then
        printf 'Invalid %s public key\n' "$role" >&2
        exit 1
    fi
    [ "$(printf '%s\n' "$key" | wc -l | tr -d ' ')" = 1 ] || exit 1
    printf 'restrict,port-forwarding %s\n' "$key" > "/etc/ssh/ssh-bridge-keys/$role"
    ssh-keygen -lf "/etc/ssh/ssh-bridge-keys/$role" >/dev/null
done
chmod 755 /etc/ssh/ssh-bridge-keys
chmod 644 /etc/ssh/ssh-bridge-keys/*
# Do not propagate deployment secrets into SSH children.
unset RELAY_HOST_KEY_B64 DEVICE_PUBLIC_KEY CLIENT_PUBLIC_KEY
/usr/sbin/sshd -t
exec /usr/sbin/sshd -D -e
