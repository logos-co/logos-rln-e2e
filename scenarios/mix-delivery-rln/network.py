#!/usr/bin/env python3
"""mix-delivery-rln driver: Delivery send(Required) through standalone Mix
intermediates, each host on one shared RLN backend. run.sh starts and funds
the seven daemons; this registers, brings the network up and asserts.
Ported from logos-libp2p-mix-rln tests/integration_e2e/shared_delivery_mix."""
import base64
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import threading
import time

ROOT = Path(os.environ["E2E_RUN_DIR"])
# Every host is a released logosctl daemon (run.sh); its client addresses it.
CLI = os.environ["UT_LOGOSCTL"]
REGISTRY = os.environ["MIX_REGISTRY_ID"]
MIX_SCOPE = os.environ["MIX_RLN_ID"]
RELAY_SCOPE = os.environ["RELAY_RLN_ID"]
MIX = "libp2p_mix_rln_module"
DELIVERY = "delivery_module"
RLN = "liblogos_rln_module"
NODES = ("sender", "m1", "m2", "m3", "exit", "relay", "receiver")
INTERMEDIATES = ("m1", "m2", "m3")
MIX_NODES = ("sender", *INTERMEDIATES, "exit")
META_TOPIC = "/mix/1/metadata/proto"
APP_TOPIC = "/mix-test/1/delivery/proto"
EVENTS = queue.Queue()
WATCHERS = []
RECEIVED = []
METADATA = set()
PUBLISHED = 0
RATE_LIMIT = 100
COVER = float(os.environ.get("E2E_MIX_COVER_FRACTION", "0.01"))
# Lowest `remaining` seen per scope on any intermediate: a quota that never
# drops means no proof was ever spent under it.
QUOTA_MIN = {}
QUOTA_NEXT = [0.0]


def say(msg):
    print("e2e: " + msg, flush=True)


def environment(node):
    # No TMPDIR: the daemon runs without one, and client and daemon must agree
    # on it (it names the local socket).
    env = {k: v for k, v in os.environ.items() if k != "TMPDIR"}
    env["LOGOSCTL_CONFIG_DIR"] = str(ROOT / "nodes" / node / "config")
    return env


def unwrap(value):
    while isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            return value
    if isinstance(value, dict) and "success" in value:
        if not value["success"]:
            raise RuntimeError(str(value.get("error")))
        return unwrap(value.get("value"))
    if isinstance(value, dict) and value.get("error") is not None:
        raise RuntimeError(str(value["error"]))
    return value


def call(node, module, method, *args):
    # json: carries byte arrays; str: preserves registry IDs and timestamp strings.
    encoded = ["json:" + json.dumps(arg) if isinstance(arg, list) else "str:" + str(arg)
               for arg in args]
    result = subprocess.run([CLI, "--json", "call", module, method, *encoded],
                            env=environment(node), text=True, capture_output=True,
                            timeout=100)
    if result.returncode:
        raise RuntimeError(f"{node} {module}.{method}: {result.stdout} {result.stderr}")
    return unwrap(json.loads(result.stdout)["result"])


def wait_for(predicate, description, timeout=120, pump=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pump:
            pump()
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError("Timed out: " + description)


def start_backend(node):
    config = {"epoch_size_sec": 10, "max_epoch_gap": 3,
              "registries": [REGISTRY], "provision": False}
    call(node, RLN, "start", json.dumps(config))
    scopes = [RELAY_SCOPE] + ([MIX_SCOPE] if node in MIX_NODES else [])
    for scope in scopes:
        say(f"{node}: registering {scope}")
        membership = call(node, RLN, "register_membership", REGISTRY, scope,
                          json.dumps([{"key": "rate_limit", "value": str(RATE_LIMIT)}]))
        def active():
            records = call(node, RLN, "get_memberships", REGISTRY)["memberships"]
            state = next(item for item in records
                         if item["membership_hash"] == membership["membership_hash"])
            if state.get("state") == "failed":
                raise AssertionError(f"{node}: registration failed: {state}")
            return state.get("state") in ("active", "grace_period")
        wait_for(active, f"{node} membership {scope}", timeout=300)
    say(f"{node}: RLN memberships active")


def watch(node):
    proc = subprocess.Popen([CLI, "--json", "watch", DELIVERY, "--event", "messageReceived"],
                            env=environment(node), text=True, stdout=subprocess.PIPE)
    WATCHERS.append(proc)
    def read():
        for line in proc.stdout:
            try:
                EVENTS.put((node, json.loads(line)))
            except json.JSONDecodeError:
                continue
        EVENTS.put((node, None))
    threading.Thread(target=read, daemon=True).start()


def start_delivery(node, peers, *, service=False):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    config = dict(logLevel="INFO", listenAddress="127.0.0.1", tcpPort=port,
                  nat="extip:127.0.0.1", extMultiAddrs=[f"/ip4/127.0.0.1/tcp/{port}"],
                  extMultiAddrsOnly=True, clusterId=198, numShardsInNetwork=1,
                  relay=service or node in INTERMEDIATES,
                  filter=service, lightpush=service, store=False,
                  peerExchange=False, discv5Discovery=False, rendezvous=False,
                  reliabilityEnabled=True, staticnodes=peers)
    # All test hosts use loopback; keep the production per-IP limit out of this topology.
    config["ip-colocation-limit"] = 0
    if node in ("sender", "exit"):
        config.update(mix=True, maxPureLibp2pPeers=100, **{"mix-rln-registry-id": REGISTRY,
                                  "mix-rln-identifier-hex": MIX_SCOPE,
                                  "mix-rln-metadata-topic": META_TOPIC})
    if node == "sender":
        config["anonymityLevel"] = "Required"
    call(node, DELIVERY, "createNode", json.dumps(config))
    watch(node)
    call(node, DELIVERY, "start")
    call(node, DELIVERY, "subscribe", META_TOPIC)
    call(node, DELIVERY, "subscribe", APP_TOPIC)
    address = None
    def listening():
        nonlocal address
        text = str(call(node, DELIVERY, "getNodeInfo", "MyMultiaddresses"))
        found = re.search(r"/ip4/127\.0\.0\.1/tcp/\d+/p2p/[A-Za-z0-9]+", text)
        if found:
            address = found.group()
        return address is not None
    wait_for(listening, f"{node} Delivery listener")
    if node in INTERMEDIATES:
        # The coordination node resolved the Relay scope from the
        # manage-backend=false preset, on the backend this host started.
        state = call(node, DELIVERY, "rlnState")
        assert RELAY_SCOPE in json.dumps(state), f"{node} rlnState lacks the relay scope: {state}"
    return address


def quota(node, scope):
    reply = call(node, RLN, "get_epoch_quota", REGISTRY, scope, str(int(time.time())))
    return int(reply["rate_limit"]), int(reply["remaining"])


def sample_quotas():
    if time.monotonic() < QUOTA_NEXT[0]:
        return
    QUOTA_NEXT[0] = time.monotonic() + 2
    for node in INTERMEDIATES:
        for name, scope in (("mix", MIX_SCOPE), ("relay", RELAY_SCOPE)):
            limit, remaining = quota(node, scope)
            assert limit == RATE_LIMIT, f"{node} {name} quota rate_limit {limit}, want {RATE_LIMIT}"
            QUOTA_MIN[name] = min(QUOTA_MIN.get(name, limit), remaining)


def pump():
    global PUBLISHED
    sample_quotas()
    for node in INTERMEDIATES:
        for frame in call(node, MIX, "drainCoordBacklog"):
            assert frame["contentTopic"] == META_TOPIC
            call(node, DELIVERY, "send", META_TOPIC, list(bytes.fromhex(frame["payloadHex"])))
            PUBLISHED += 1
    while True:
        try:
            node, event = EVENTS.get_nowait()
        except queue.Empty:
            return
        if event is None:
            raise AssertionError(f"{node} event watcher exited")
        if event.get("event") != "messageReceived":
            continue
        data = event["data"]
        topic = data["arg1"]
        encoded = data["arg2"]["_bytes"]
        payload = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        if topic == META_TOPIC:
            METADATA.add((node, payload))
            if node in INTERMEDIATES:
                call(node, MIX, "deliverCoordFrame", topic, payload.hex())
        elif topic == APP_TOPIC:
            RECEIVED.append((node, payload))


def main():
    # Registry setup shares on-chain state; confirm each registration before the next.
    for node in NODES:
        start_backend(node)
    addresses = {}
    addresses["exit"] = start_delivery("exit", [], service=True)
    addresses["relay"] = start_delivery("relay", [addresses["exit"]], service=True)
    for node in ("sender", *INTERMEDIATES, "receiver"):
        peers = ([addresses["exit"]] if node == "sender"
                 else [addresses["relay"], addresses["exit"]])
        addresses[node] = start_delivery(node, peers)
    for node in INTERMEDIATES:
        config = {"addrs": ["/ip4/127.0.0.1/tcp/0"],
                  "transport": "tcp",
                  "mix": {"cover": {"rateFraction": COVER}},
                  "rln": {"registryId": REGISTRY,
                          "rlnIdentifierHex": MIX_SCOPE,
                          "epochDurationSeconds": 10,
                          "maxEpochGap": 3,
                          "userMessageLimit": RATE_LIMIT,
                          "proofMetadataContentTopic": META_TOPIC}}
        call(node, MIX, "createNode", json.dumps(config))
        call(node, MIX, "start")
        say(f"{node}: standalone Mix intermediate started")
    records = {node: call(node, MIX if node in INTERMEDIATES else DELIVERY,
                          "getLocalMixPeerRecord") for node in MIX_NODES}
    for node, record in records.items():
        missing = [k for k in ("peerId", "multiaddrs", "mixPubKeyHex", "libp2pPubKeyHex")
                   if not record.get(k)]
        assert not missing, f"{node} Mix peer record lacks {missing}: {record}"
    for node in INTERMEDIATES:
        # Separate switches: the Mix record is not the Delivery node's identity.
        delivery_peer = addresses[node].rsplit("/p2p/", 1)[1]
        assert records[node]["peerId"] != delivery_peer, \
            f"{node} Mix and Delivery share peer id {delivery_peer}"
    for node in MIX_NODES:
        module = MIX if node in INTERMEDIATES else DELIVERY
        for peer in MIX_NODES:
            if peer != node:
                call(node, module, "addMixPeer", json.dumps(records[peer]))
    for node in INTERMEDIATES:
        pool = json.dumps(call(node, MIX, "listMixPeers"))
        absent = [p for p in MIX_NODES if p != node and records[p]["peerId"] not in pool]
        assert not absent, f"{node} Mix pool lacks {absent}: {pool}"
    say("Mix peer records exchanged; every intermediate's pool holds the other four")
    # Let Relay meshes and Filter subscriptions form while continuing coordination.
    ready_at = time.monotonic() + 12
    wait_for(lambda: time.monotonic() >= ready_at, "coordination mesh", pump=pump)
    payload = b"Delivery Required through standalone Mix and shared RLN"
    call("sender", DELIVERY, "send", APP_TOPIC, list(payload))
    wait_for(lambda: ("receiver", payload) in RECEIVED, "mixified message at receiver",
             timeout=180, pump=pump)
    assert PUBLISHED > 0, "No standalone hop validated and published proof metadata"
    wait_for(lambda: all(any(n == node for n, _ in METADATA) for node in MIX_NODES),
             "protected metadata delivery to every Mix participant", pump=pump)
    say(f"Required message reached the receiver through standalone Mix "
        f"({PUBLISHED} metadata frames published by intermediates)")
    # Keep coordinating for two epochs so the quota samples straddle the hop work.
    settle = time.monotonic() + 20
    wait_for(lambda: time.monotonic() >= settle, "quota samples", pump=pump)
    for name in ("mix", "relay"):
        assert QUOTA_MIN.get(name, RATE_LIMIT) < RATE_LIMIT, \
            f"no intermediate ever spent {name} quota (min remaining {QUOTA_MIN.get(name)})"
    say(f"quotas: rate_limit {RATE_LIMIT} on both scopes; min remaining {QUOTA_MIN}")
    for node in INTERMEDIATES:
        call(node, MIX, "stop")
    blocked = b"Required must not bypass stopped intermediates"
    call("sender", DELIVERY, "send", APP_TOPIC, list(blocked))
    control = b"Relay and Filter remain available"
    call("exit", DELIVERY, "send", APP_TOPIC, list(control))
    wait_for(lambda: ("receiver", control) in RECEIVED, "ordinary delivery control", pump=pump)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        pump()
        assert ("receiver", blocked) not in RECEIVED, "Required fell back to a direct path"
        time.sleep(0.2)
    say("stopped intermediates block Required delivery; plain Relay still delivers")


if __name__ == "__main__":
    try:
        main()
    finally:
        for watcher in WATCHERS:
            watcher.terminate()
        for watcher in WATCHERS:
            watcher.wait(timeout=5)
