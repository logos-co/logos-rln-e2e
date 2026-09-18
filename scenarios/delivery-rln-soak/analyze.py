#!/usr/bin/env python3
"""Correlate a delivery-rln-soak run's send log with both nodes' event streams.

Three sources, joined on identifiers the stack already carries:

  soak-sends.csv   one row per send: phase, round, node, seq, requestId, and a
                   nanosecond wall clock taken immediately before the call.
  soak-quota.csv   the module's get_epoch_quota either side of every round.
  events-*.jsonl   what each node's delivery_module emitted.

Every delivery event's LAST argument is a nanosecond timestamp on the same
realtime clock the send log uses, so latency needs no clock alignment. The arg
layouts (delivery_module_plugin.h, logos_events):

  messagePropagated(requestId, messageHash, ts)
  messageError(requestId, messageHash, error, ts)
  messageSent(requestId, messageHash, ts)
  messageReceived(messageHash, contentTopic, payload, source, ts)

`messageReceived`'s last argument is NOT an event time. Every other delivery
event passes the outer envelope's `timestamp`, but message_received passes
`message.timestamp` (delivery_module_plugin.cpp:339) — the stamp the SENDER put
on the message in `toWakuMessage`. So it is earlier than the sender's own
`messagePropagated`, and differencing the two yields a negative "latency".
Receive time is therefore not observable from this event at all; the receiver's
`rlnValidateProofRequest` is, and its event timestamp is what this module uses
as the delivery clock.
  rlnGenerateProofRequest(reqId, registry, rlnIdentifier, signalHex, epochTs, ts)
  rlnValidateProofRequest(reqId, registry, rlnIdentifier, signalHex, epochTs,
                          proofJson, ts)

The rln* family is emitted under the dispatch-method name upstream and under
the plain name on the retired fork; both are normalised here.

A proof's signal is payload || contentTopic || timestamp, so a send's unique
payload text is a prefix of its signal hex. That is what maps a generate-proof
request back to the message that caused it — and therefore what counts the
retries a single message provokes.
"""
import argparse
import collections
import csv
import json
import sys


# ---------- reading ---------------------------------------------------------

def norm_event(name):
    if name.startswith("dispatchRln") and name.endswith("Event"):
        return "rln" + name[len("dispatchRln"):-len("Event")]
    return name


def load_events(path):
    rows = []
    try:
        fh = open(path)
    except OSError as e:
        sys.exit("analyze: cannot read events %s: %s" % (path, e))
    with fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            rows.append((norm_event(d.get("event") or ""), d.get("data") or {}))
    return rows


def arg(data, n, default=""):
    return data.get("arg%d" % n, default)


class NodeEvents(object):
    """One node's stream, indexed the ways the joins need."""

    def __init__(self, path):
        self.path = path
        self.propagated = {}        # requestId -> (msgHash, ts_ns)
        self.errored = {}           # requestId -> (msgHash, error, ts_ns)
        self.sent = {}              # requestId -> ts_ns
        self.received = {}          # msgHash -> (source, ts_ns)
        self.generate = []          # (signalHex, epochTs, ts_ns)
        self.validate = []          # (signalHex, epochTs, ts_ns)
        self.counts = collections.Counter()
        for ev, d in load_events(path):
            self.counts[ev] += 1
            if ev == "messagePropagated":
                self.propagated[str(arg(d, 0))] = (str(arg(d, 1)), int(arg(d, 2, 0)))
            elif ev == "messageError":
                self.errored[str(arg(d, 0))] = (str(arg(d, 1)), str(arg(d, 2)), int(arg(d, 3, 0)))
            elif ev == "messageSent":
                self.sent[str(arg(d, 0))] = int(arg(d, 2, 0))
            elif ev == "messageReceived":
                # First receipt wins; a duplicate delivery must not move the clock.
                self.received.setdefault(str(arg(d, 0)), (str(arg(d, 3)), int(arg(d, 4, 0))))
            elif ev == "rlnGenerateProofRequest":
                self.generate.append((str(arg(d, 3)), str(arg(d, 4)), int(arg(d, 5, 0))))
            elif ev == "rlnValidateProofRequest":
                self.validate.append((str(arg(d, 3)), str(arg(d, 4)), int(arg(d, 6, 0))))


# ---------- stats -----------------------------------------------------------

def pct(values, p):
    """Nearest-rank percentile. Small n, so no interpolation games."""
    if not values:
        return None
    s = sorted(values)
    k = int(round(p / 100.0 * len(s) + 0.5)) - 1
    return s[max(0, min(len(s) - 1, k))]


def ms(ns):
    return None if ns is None else round(ns / 1e6, 1)


def latency_row(label, values):
    if not values:
        return "%-22s   (none)" % label
    return "%-22s n=%-4d p50 %8.1f  p95 %8.1f  max %8.1f  min %8.1f ms" % (
        label, len(values), ms(pct(values, 50)), ms(pct(values, 95)),
        ms(max(values)), ms(min(values)))


# ---------- main ------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sends", required=True)
    ap.add_argument("--quota", required=True)
    ap.add_argument("--events", action="append", required=True,
                    help="<node>=<path to events-delivery_module.N.jsonl>")
    ap.add_argument("--rate-limit", type=int, required=True)
    ap.add_argument("--epoch-size", type=int, required=True)
    ap.add_argument("--json", help="write the machine-readable summary here")
    args = ap.parse_args()

    nodes = {}
    for spec in args.events:
        name, _, path = spec.partition("=")
        nodes[name] = NodeEvents(path)
    names = sorted(nodes)
    peer = {n: [m for m in names if m != n][0] for n in names} if len(names) == 2 else {}
    if not peer:
        sys.exit("analyze: expected exactly two --events nodes, got %r" % names)

    with open(args.sends) as f:
        sends = list(csv.DictReader(f))
    with open(args.quota) as f:
        quota = list(csv.DictReader(f))
    if not sends:
        sys.exit("analyze: %s has no sends" % args.sends)

    # ---- classify every send ------------------------------------------------
    for s in sends:
        node, rid = s["node"], s["request_id"]
        ev = nodes[node]
        s["t0"] = int(s["t_send_ns"])
        s["payload_hex"] = ("soak %s r%s s%s from %s" % (
            s["phase"], s["round"], s["seq"], node)).encode().hex()
        prop = ev.propagated.get(rid)
        err = ev.errored.get(rid)
        s["msg_hash"] = prop[0] if prop else (err[0] if err else "")
        s["t_prop"] = prop[1] if prop else None
        s["error"] = err[1] if err else ""
        s["t_err"] = err[2] if err else None
        recv = nodes[peer[node]].received.get(s["msg_hash"]) if s["msg_hash"] else None
        # Presence only — see the note on messageReceived's timestamp above.
        s["received_by_peer"] = recv is not None
        s["t_stamped"] = recv[1] if recv else None
        s["recv_source"] = recv[0] if recv else ""
        s["t_peer_validated"] = None
        s["outcome"] = "propagated" if prop else ("errored" if err else "parked")

    # ---- generate-proof calls, mapped back to their message ------------------
    # The signal is payload || contentTopic || timestamp, so a send's payload
    # hex is a prefix of the signal hex of every proof attempt it caused.
    by_prefix = {s["payload_hex"]: s for s in sends}
    for s in sends:
        s["gen_calls"] = 0
        s["gen_epochs"] = set()
    # The peer's validate-request event is the only ns-resolution clock on the
    # receiving side, so it is the delivery latency this scenario reports.
    for node in names:
        for sig, _epoch_ts, ts in nodes[node].validate:
            for prefix, s in by_prefix.items():
                # the PEER validated it, so the send came from the other node
                if sig.startswith(prefix) and s["node"] != node:
                    if s["t_peer_validated"] is None or ts < s["t_peer_validated"]:
                        s["t_peer_validated"] = ts
                    break

    unmapped_gen = 0
    for node in names:
        for sig, epoch_ts, _ts in nodes[node].generate:
            hit = None
            for prefix, s in by_prefix.items():
                if sig.startswith(prefix) and s["node"] == node:
                    hit = s
                    break
            if hit is None:
                unmapped_gen += 1
                continue
            hit["gen_calls"] += 1
            hit["gen_epochs"].add(epoch_ts)

    # ---- assertions ---------------------------------------------------------
    failures = []

    baseline = [s for s in sends if s["phase"] == "baseline"]
    bad = [s for s in baseline if s["outcome"] != "propagated"]
    if bad:
        failures.append(
            "baseline: %d/%d sends did not propagate under an unspent budget "
            "(%s) — the message path is broken before load is even a factor"
            % (len(bad), len(baseline),
               ", ".join("%s r%s s%s %s%s" % (b["node"], b["round"], b["seq"], b["outcome"],
                                              ": " + b["error"] if b["error"] else "")
                         for b in bad[:4])))
    bad = [s for s in baseline if s["outcome"] == "propagated" and not s["received_by_peer"]]
    if bad:
        failures.append(
            "baseline: %d/%d propagated messages never reached the peer — on a "
            "two-node static mesh nothing should be lost"
            % (len(bad), len(baseline)))

    sat_rounds = sorted({s["round"] for s in sends if s["phase"] == "saturation"},
                        key=int)
    for rnd in sat_rounds:
        for node in names:
            grp = [s for s in sends
                   if s["phase"] == "saturation" and s["round"] == rnd and s["node"] == node]
            got = sum(1 for s in grp if s["outcome"] == "propagated")
            if got != args.rate_limit:
                failures.append(
                    "saturation round %s %s: %d sends propagated, want exactly "
                    "%d — the epoch budget was %s"
                    % (rnd, node, got, args.rate_limit,
                       "overspent" if got > args.rate_limit else "underspent"))

    # Quota bookkeeping. `before` is read just past an epoch boundary, so a
    # refilled budget is the claim; `after` is read inside the same epoch.
    for q in quota:
        if q["phase"] != "saturation":
            continue
        rl, rem = int(q["rate_limit"]), int(q["remaining"])
        if rl != args.rate_limit:
            failures.append("saturation round %s %s %s: rate_limit %d != %d"
                            % (q["round"], q["node"], q["when"], rl, args.rate_limit))
        if q["when"] == "before" and rem != args.rate_limit:
            failures.append(
                "saturation round %s %s: the epoch opened with %d/%d slots, not a "
                "full budget — the epoch did not roll between rounds"
                % (q["round"], q["node"], rem, args.rate_limit))
        if q["when"] == "after" and rem != 0:
            failures.append(
                "saturation round %s %s: %d/%d slots left after a burst of more "
                "than the budget — the budget was not spent"
                % (q["round"], q["node"], rem, args.rate_limit))

    lost = [s for s in sends
            if s["phase"] != "warmup" and s["outcome"] == "propagated"
            and not s["received_by_peer"]]
    if lost:
        failures.append(
            "%d propagated messages never reached the peer: %s"
            % (len(lost), ", ".join("%s r%s s%s" % (s["node"], s["round"], s["seq"])
                                    for s in lost[:6])))

    # Nothing may arrive that the peer did not publish through a proof.
    for node in names:
        published = {s["msg_hash"] for s in sends
                     if s["node"] == peer[node] and s["outcome"] == "propagated"}
        mine = {s["msg_hash"] for s in sends if s["node"] == node and s["msg_hash"]}
        stray = set(nodes[node].received) - published - mine
        if stray:
            failures.append(
                "%s received %d message(s) neither node published in this run: %s"
                % (node, len(stray), ", ".join(sorted(stray)[:3])))

    # ---- report -------------------------------------------------------------
    out = []
    w = out.append

    w("e2e: soak summary — budget %d slots/epoch, epoch %ds, %d sends total"
      % (args.rate_limit, args.epoch_size, len(sends)))
    w("")

    w("e2e: latency")
    for phase in ("baseline", "saturation"):   # warm-up is not a measurement
        grp = [s for s in sends if s["phase"] == phase and s["outcome"] == "propagated"]
        prop = [s["t_prop"] - s["t0"] for s in grp if s["t_prop"]]
        val = [s["t_peer_validated"] - s["t0"] for s in grp if s["t_peer_validated"]]
        stamp = [s["t_stamped"] - s["t0"] for s in grp if s["t_stamped"]]
        w("e2e:   %-10s %s" % (phase, latency_row("send -> peer validated", val)))
        w("e2e:   %-10s %s" % ("", latency_row("send -> propagated", prop)))
        w("e2e:   %-10s %s" % ("", latency_row("send -> msg stamped", stamp)))
    w("e2e:   send -> peer validated is the delivery latency: the call returning, the")
    w("e2e:     proof generated, gossipsub, and the peer's validator reached.")
    w("e2e:   send -> propagated is the SENDER's own completion event, which it emits")
    w("e2e:     after the peer has already seen the message.")
    w("e2e:   send -> msg stamped is only the send call's own overhead (messageReceived")
    w("e2e:     carries the sender's message stamp, not a receive time).")
    w("e2e:   baseline runs under budget, so it is the only measurement with no parked")
    w("e2e:     task retrying a proof once a second in the background.")
    w("")

    w("e2e: per round (propagated / errored / parked, per node)")
    order = {"warmup": 0, "baseline": 1, "saturation": 2}
    for phase, rnd in sorted({(s["phase"], s["round"]) for s in sends},
                             key=lambda x: (order.get(x[0], 9), int(x[1]))):
        cells = []
        for node in names:
            grp = [s for s in sends
                   if s["phase"] == phase and s["round"] == rnd and s["node"] == node]
            c = collections.Counter(s["outcome"] for s in grp)
            q = [x for x in quota
                 if x["phase"] == phase and x["round"] == rnd and x["node"] == node]
            qs = "/".join(x["remaining"] for x in sorted(q, key=lambda x: x["when"] != "before"))
            cells.append("%s %d/%d/%d slots %s" % (
                node, c["propagated"], c["errored"], c["parked"], qs or "?"))
        w("e2e:   %-10s r%-3s %s" % (phase, rnd, "   ".join(cells)))
    w("e2e:   slots column is remaining before/after the burst")
    w("")

    over = [s for s in sends if s["phase"] == "saturation" and s["outcome"] != "propagated"]
    inb = [s for s in sends if s["outcome"] == "propagated"]
    w("e2e: over-quota sends — measured, not asserted")
    if not over:
        w("e2e:   none: every send propagated, so the budget was never actually exceeded")
    else:
        c = collections.Counter(s["outcome"] for s in over)
        w("e2e:   %d sends beyond budget: %d errored, %d still parked at collection"
          % (len(over), c["errored"], c["parked"]))
        for msg, n in collections.Counter(s["error"] for s in over if s["error"]).most_common():
            w("e2e:   %4dx %s" % (n, msg))
        deaths = [(s["t_err"] - s["t0"]) / 1e9 for s in over if s["t_err"]]
        if deaths:
            w("e2e:   died %.1fs..%.1fs after their send" % (min(deaths), max(deaths)))
        retries = [s["gen_calls"] for s in over]
        if retries:
            w("e2e:   proof attempts per refused message: min %d median %d max %d"
              % (min(retries), pct(retries, 50), max(retries)))
        pinned = [s for s in over if len(s["gen_epochs"]) == 1 and s["gen_calls"] > 1]
        moved = [s for s in over if len(s["gen_epochs"]) > 1]
        if pinned and not moved:
            w("e2e:   every refused message retried a CONSTANT epoch timestamp — it can")
            w("e2e:   never find a fresh budget. attachRlnProof takes the epoch from")
            w("e2e:   message.timestamp (logos_delivery/api/types.nim), fixed at send")
            w("e2e:   and never restamped, so the retry recharges the epoch that just")
            w("e2e:   refused it. An over-quota message is lost, not deferred.")
        elif moved:
            w("e2e:   %d refused messages DID move to a later epoch timestamp — the"
              % len(moved))
            w("e2e:   library restamps on retry after all; re-read the scenario header,")
            w("e2e:   its account of the overflow path is out of date.")
        else:
            w("e2e:   no refused message was retried at all (no second proof attempt),")
            w("e2e:   so the send service is not the thing parking them — check whether")
            w("e2e:   the messages reached admitAndProve in the first place.")
    w("")

    gen_in = [s["gen_calls"] for s in inb]
    w("e2e: proof work")
    w("e2e:   %d generate-proof requests across both nodes (%d mapped to a send%s)"
      % (sum(len(nodes[n].generate) for n in names), sum(s["gen_calls"] for s in sends),
         ", %d from warm-up or other pre-measurement traffic" % unmapped_gen
         if unmapped_gen else ""))
    if gen_in:
        w("e2e:   delivered messages cost min %d median %d max %d attempts each"
          % (min(gen_in), pct(gen_in, 50), max(gen_in)))
    for node in names:
        w("e2e:   %s: %d generate, %d validate, %d received"
          % (node, len(nodes[node].generate), len(nodes[node].validate),
             len(nodes[node].received)))
    w("")

    if failures:
        w("e2e: FAIL — %d assertion(s)" % len(failures))
        for f in failures:
            w("e2e:   %s" % f)
    else:
        w("e2e: assertions OK — baseline delivered, every saturation round spent")
        w("e2e:   exactly %d slots per node, every epoch refilled, nothing lost or"
          % args.rate_limit)
        w("e2e:   delivered unproven.")

    print("\n".join(out))

    if args.json:
        with open(args.json, "w") as f:
            json.dump({
                "rate_limit": args.rate_limit,
                "epoch_size_sec": args.epoch_size,
                "failures": failures,
                "sends": [{k: (sorted(v) if isinstance(v, set) else v)
                           for k, v in s.items() if k != "payload_hex"} for s in sends],
                "quota": quota,
                "event_counts": {n: dict(nodes[n].counts) for n in names},
            }, f, indent=1)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
