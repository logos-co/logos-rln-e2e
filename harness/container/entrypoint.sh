#!/usr/bin/env bash
# Per-container entrypoint: install the freshly-built libp2p_module .lgx (mounted
# at /artifacts) over the image's baked copy, then run the logoscore daemon in
# the foreground so the container stays up. The orchestrator drives roles via
# `docker compose exec` afterward.
#
# Listen on THIS container's IP only (not 0.0.0.0). Binding 0.0.0.0 makes the node
# advertise BOTH 127.0.0.1 and the container IP, and the mix then sometimes routes
# a next-hop / SURB-reply to 127.0.0.1 -> it dials its own loopback -> Noise
# peer-id mismatch -> dropped. Advertising only the container IP avoids that.
set -euo pipefail
export PATH=/rttools/bin:$PATH

ip=$(python3 -c 'import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try:
  s.connect(("10.255.255.255",1)); print(s.getsockname()[0])
except Exception: print("")
finally: s.close()' 2>/dev/null)
if [ -n "$ip" ]; then
  export LIBP2P_LISTEN_ADDRS="/ip4/$ip/tcp/9000"
fi

if [ -f /artifacts/libp2p_module.lgx ]; then
  lgx=/artifacts/libp2p_module.lgx
  name=$(tar xzOf "$lgx" manifest.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')
  tmp=$(mktemp -d); tar xzf "$lgx" -C "$tmp"
  var=$(ls "$tmp/variants" | head -1)
  rm -rf "/modules/$name"; mkdir -p "/modules/$name"
  cp "$tmp/manifest.json" "/modules/$name/"
  cp -L "$tmp/variants/$var/"* "/modules/$name/"
  printf '%s' "$var" > "/modules/$name/variant"
fi
echo "[entrypoint] installed module; listen=${LIBP2P_LISTEN_ADDRS:-default}"

exec /logoscore/bin/logoscore -m /modules -D
