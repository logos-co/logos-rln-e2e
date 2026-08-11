# shellcheck shell=bash
# scenarios/mix/lib/nodes.sh — 5-node wakunode2 topology: config generation,
# lifecycle, readiness, metrics. Node identities are the stack's own sim
# fixtures (nodekey → peerId matches tools/setup_chain_credentials.nim's
# manifest; keystore filenames are peerId-derived, so these must not drift).
#
# Each node runs from its own cwd under $E2E_RUN_DIR/mix/n<N> with its own
# copy of rln_tree.db + keystore — the plugin resolves both relative to cwd
# (hardcoded names), and per-node copies keep its saveTree() writes isolated.
#
# Ports follow the stack's sim scheme (ports-shift N+1): tcp 6000(N+1),
# metrics 800(8+N+1) — i.e. tcp 60001-60005, metrics 8009-8013.

_MIX_NODES=5
_MIX_BOOTSTRAP_MADDR="/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"

# n<idx> -> nodekey / mixkey / peerId
_mix_fixture() {
    case "$1" in
        0) printf '%s %s %s' f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a \
            a87db88246ec0eedda347b9b643864bee3d6933eb15ba41e6d58cb678d813258 \
            16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o ;;
        1) printf '%s %s %s' 09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684 \
            c86029e02c05a7e25182974b519d0d52fcbafeca6fe191fbb64857fb05be1a53 \
            16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF ;;
        2) printf '%s %s %s' ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e \
            b858ac16bbb551c4b2973313b1c8c8f7ea469fca03f1608d200bbf58d388ec7f \
            16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA ;;
        3) printf '%s %s %s' 42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6 \
            d8bd379bb394b0f22dd236d63af9f1a9bc45266beffc3fbbe19e8b6575f2535b \
            16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f ;;
        4) printf '%s %s %s' 3ce887b3c34b7a92dd2868af33941ed1dbec4893b054572cd5078da09dd923d4 \
            780fff09e51e98df574e266bf3266ec6a3a1ddfcf7da826a349a29c137009d49 \
            16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu ;;
        *) return 1 ;;
    esac
}

mix_node_peerid() { _mix_fixture "$1" | awk '{print $3}'; }
mix_node_metrics_port() { printf '%s' $((8008 + $1 + 1)); }

# mix_nodes_configs <dir> — write config0..4.toml. Deviations from the
# stack's sim set: INFO logs (TRACE writes GBs) and cover traffic ENABLED —
# cover emission is what exercises per-hop RLN without an interactive client.
mix_nodes_configs() {
    local dir="$1" i nodekey mixkey peerid extra
    mkdir -p "$dir"
    for i in 0 1 2 3 4; do
        read -r nodekey mixkey peerid <<EOF
$(_mix_fixture "$i")
EOF
        extra=""
        if [ "$i" = 0 ]; then
            extra='store = true'
        else
            extra="store = false
kad-bootstrap-node = [\"$_MIX_BOOTSTRAP_MADDR\"]"
        fi
        cat > "$dir/config$i.toml" <<EOF
log-level = "${E2E_MIX_LOG_LEVEL:-INFO}"
relay = true
mix = true
filter = true
lightpush = true
max-connections = 150
peer-exchange = false
metrics-logging = false
metrics-server = true
cluster-id = 2
discv5-discovery = false
discv5-udp-port = $((9000 + i))
enable-kad-discovery = true
rest = true
rest-admin = true
ports-shift = $((i + 1))
num-shards-in-network = 1
shard = [0]
agent-string = "nwaku-mix"
nodekey = "$nodekey"
mixkey = "$mixkey"
rendezvous = false
listen-address = "127.0.0.1"
nat = "extip:127.0.0.1"
ext-multiaddr = ["/ip4/127.0.0.1/tcp/$((60000 + i + 1))"]
ext-multiaddr-only = true
ip-colocation-limit = 0
mix-user-message-limit = ${E2E_MIX_RATE_LIMIT:-100}
mix-disable-spam-protection = false
mix-disable-cover-traffic = false
$extra
EOF
    done
    say "mix: wrote 5 node configs -> $dir"
}

_MIX_NODE_PIDS=""

_mix_node_launch() {
    local cfgdir="$1" creds="$2" i="$3" peerid ndir pid
    peerid=$(mix_node_peerid "$i")
    ndir="$E2E_RUN_DIR/mix/n$i"
    mkdir -p "$ndir"
    cp "$creds/rln_tree.db" "$ndir/" || die "no rln_tree.db in $creds"
    cp "$creds/rln_keystore_$peerid.json" "$ndir/" || die "no keystore for n$i ($peerid)"
    ( cd "$ndir" && exec "$MIX_STACK/build/wakunode2" --config-file="$cfgdir/config$i.toml" ) \
        > "$E2E_RUN_DIR/mix/n$i.log" 2>&1 &
    pid=$!
    _MIX_NODE_PIDS="$_MIX_NODE_PIDS $pid"
    say "mix: n$i up (pid $pid, peer ${peerid:0:16}…)"
}

# A node is ready when its spam protection is up. Deliberately log-based:
# once cover traffic starts, proof generation (~100-350ms each, R/epoch
# cadence) keeps the single-threaded event loop near saturation, so HTTP
# probes time out even though the node is healthy — the metrics endpoint is
# only scraped once, after the traffic window. ("Node setup complete" is
# also unused: it lands late on relays that are already covering.)
_mix_node_ready() {
    grep -q "MixRlnSpamProtection started" "$E2E_RUN_DIR/mix/n$1.log" 2>/dev/null
}

_mix_wait_ready() {
    local want="$1" budget="$2" waited=0 ready i
    shift 2
    while :; do
        ready=0
        for i in "$@"; do _mix_node_ready "$i" && ready=$((ready + 1)); done
        [ "$ready" = "$want" ] && return 0
        [ "$waited" -ge "$budget" ] && {
            for i in "$@"; do
                say "mix: n$i log tail:"; tail -5 "$E2E_RUN_DIR/mix/n$i.log" >&2 || true
            done
            die "mix: only $ready/$want nodes ready after ${budget}s"
        }
        sleep 5; waited=$((waited + 5))
    done
}

# mix_nodes_start <configs-dir> <creds-dir> — per-node cwd, staged
# credentials. Bootstrap strictly first (the sim runbook's ordering): relays
# that dial an unready bootstrap back off for minutes and stall their whole
# setup. Relay setup still takes ~60-70s after that (kad-bootstrap path), so
# readiness is the spam-protection log line, not HTTP.
mix_nodes_start() {
    local cfgdir="$1" creds="$2" i
    [ -x "$MIX_STACK/build/wakunode2" ] || die "no wakunode2 (run stack.sh build)"
    local budget="${E2E_MIX_START_TIMEOUT_S:-240}"
    _mix_node_launch "$cfgdir" "$creds" 0
    say "mix: waiting for bootstrap"
    _mix_wait_ready 1 "$budget" 0
    for i in 1 2 3 4; do _mix_node_launch "$cfgdir" "$creds" "$i"; done
    say "mix: waiting for relays"
    _mix_wait_ready 4 "$budget" 1 2 3 4
    say "mix: all $_MIX_NODES nodes ready"
}

mix_nodes_stop() {
    if [ "${E2E_KEEP:-0}" = "1" ]; then
        say "mix: E2E_KEEP=1 — leaving nodes up (pids:$_MIX_NODE_PIDS)"
        return 0
    fi
    local pid
    for pid in $_MIX_NODE_PIDS; do kill "$pid" 2>/dev/null || true; done
    _MIX_NODE_PIDS=""
}

# mix_metric <node-idx> <series-prefix> — sum of all matching counter values
# on the node's metrics endpoint (labels collapsed), "0" when absent. Plain
# prefix match: series names carry {label="…"} braces, which are ERE interval
# syntax — no regex.
mix_metric() {
    local port
    port=$(mix_node_metrics_port "$1")
    curl -s -m 15 "http://127.0.0.1:$port/metrics" \
        | awk -v p="$2" 'index($0, p) == 1 {s += $NF} END {printf "%d", s}'
}
