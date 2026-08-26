## RlnConsumer — a Nim mock of logos-delivery's RLN integration, hosted as a
## logos-core module. The C++ plugin drives this library over the nim-ffi C
## ABI; every RLN operation goes out through the mirrored delivery seam
## (rln_seam.nim) and comes back from the real liblogos_rln_module via the
## plugin's bridge. See ../../README.md for the architecture.
##
## Registration is async by design: `registerMembership` returns the module's
## reply as soon as the dispatch returns (normally `state:"pending"`) and a
## background poller — the shape logos-delivery itself will need — tracks the
## membership until it leaves `pending`. Activation is observed by the harness
## via `getMembershipState` polling and the plugin's re-emitted
## `membership_state_changed` event, never by one long-blocking call.

import std/[json, strutils]
import ffi, chronos, results
import ./rln_seam

type
  ConsumerState = object
    registryId: string
    rlnIdentifierHex: string
    epochSizeSec: int
    opTimeout: Duration # rlnInvoke budget; "10" reproduces delivery's hard limit
    pollInterval: Duration
    confirmBudget: Duration
    lastPolled: string # the confirmation poller's most recent state reply

  RlnConsumer = object
    state: ref ConsumerState # shared across handler copies of the ctx object

declareLibrary("rlnconsumer", RlnConsumer, defaultABIFormat = "c")

type RlnConsumerConfig {.ffi.} = object
  registryId: string # CAIP-10 "logos:<ref>:<64-hex config account>"
  rlnIdentifierHex: string # 64-hex application scope key
  epochSizeSec: string # abi=c crosses scalars as strings; parsed here
  opTimeoutSec: string # default "30"
  pollIntervalSec: string # default "5"
  confirmBudgetSec: string # default "300"

# ---------------------------------------------------------------- helpers

proc intOr(s: string, fallback: int): int =
  try:
    if s.len == 0: fallback else: parseInt(s)
  except ValueError:
    fallback

proc scopePayload(s: ref ConsumerState): JsonNode =
  %*{"registry_id": s.registryId, "rln_identifier_hex": s.rlnIdentifierHex}

proc invokeUnwrap(
    s: ref ConsumerState, op: RlnOp, payload: JsonNode
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  ## One seam round-trip. The host answers {"ok":true,"value":<module reply>}
  ## or {"ok":false,"error":{class,kind,message}}; unwrap to value-or-error.
  let raw = (await rlnInvoke(op, $payload, s.opTimeout)).valueOr:
    return err("seam: " & error)
  try:
    let parsed = parseJson(raw)
    if parsed{"ok"}.getBool(false):
      return ok($parsed{"value"})
    return err($parsed{"error"})
  except CatchableError as e:
    return err("seam reply not JSON: " & e.msg)

proc hexToBytes(hex: string): seq[byte] {.raises: [ValueError].} =
  var digits = hex.strip()
  if digits.startsWith("0x") or digits.startsWith("0X"):
    digits = digits[2 .. ^1]
  if digits.len mod 2 != 0:
    raise newException(ValueError, "odd hex length")
  result = newSeq[byte](digits.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(digits[i * 2 .. i * 2 + 1]))

proc bytesToHex(bs: openArray[byte]): string =
  const digits = "0123456789abcdef"
  result = newString(bs.len * 2)
  for i, b in bs:
    result[i * 2] = digits[int(b shr 4)]
    result[i * 2 + 1] = digits[int(b and 0x0f)]

# The signal logos-delivery proves over: payload ++ contentTopic ++ timestamp
# (waku/rln/proof.nim toRLNSignal). Timestamp bytes use stew toBytes(uint64)'s
# default order; both proving and validating go through this one function, so
# the e2e is internally consistent either way — parity with delivery's exact
# byte order is asserted when the integration lands.
proc buildSignal(payload: seq[byte], contentTopic: string, timestamp: uint64): seq[byte] =
  result = payload
  result.add cast[seq[byte]](contentTopic)
  var ts = timestamp
  for i in countdown(7, 0):
    result.add byte((ts shr (i * 8)) and 0xff)

# ------------------------------------------------------- lifecycle + surface

proc rlnconsumerCreate*(config: RlnConsumerConfig): Future[Result[RlnConsumer, string]] {.ffiCtor.} =
  ## Create a consumer bound to one (registry_id, rln_identifier) scope.
  if config.registryId.len == 0 or config.rlnIdentifierHex.len == 0:
    return err("registryId and rlnIdentifierHex are required")
  let s = (ref ConsumerState)(
    registryId: config.registryId,
    rlnIdentifierHex: config.rlnIdentifierHex,
    epochSizeSec: intOr(config.epochSizeSec, 600),
    opTimeout: intOr(config.opTimeoutSec, 30).seconds,
    pollInterval: intOr(config.pollIntervalSec, 5).seconds,
    confirmBudget: intOr(config.confirmBudgetSec, 300).seconds,
  )
  return ok(RlnConsumer(state: s))

proc rlnconsumer_destroy*(c: RlnConsumer) {.ffiDtor.} =
  ## Releases the consumer context. The seam and its host stay up.
  discard

proc rlnconsumerPing*(c: RlnConsumer, text: string): Future[Result[string, string]] {.ffi.} =
  ## Liveness probe for the harness selftest: proves the C++ -> Nim leg.
  return ok("pong: " & text)

proc rlnconsumerSlowPing*(c: RlnConsumer, text: string): Future[Result[string, string]] {.ffi.} =
  ## Crosses one nim-ffi RET_STALE_WARN tick (~5s) on purpose: proves the
  ## plugin's ticket bridge treats the tick as non-terminal.
  await sleepAsync(7.seconds)
  return ok("slow pong: " & text)

proc rlnconsumerStartRln*(c: RlnConsumer): Future[Result[string, string]] {.ffi.} =
  ## Seam `start`: configures the module's epoch size and warms the
  ## registry's root window.
  let cfg =
    %*{"epoch_size_sec": c.state.epochSizeSec, "registries": [c.state.registryId]}
  return await invokeUnwrap(c.state, RlnOpStart, %*{"config_json": $cfg})

proc rlnconsumerStopRln*(c: RlnConsumer): Future[Result[string, string]] {.ffi.} =
  return await invokeUnwrap(c.state, RlnOpStop, newJObject())

proc confirmationPoller(s: ref ConsumerState) {.async: (raises: []).} =
  ## The delivery-shaped async-registration follow-up: track the membership
  ## out of `pending` in the background. Purely observational — the harness
  ## still polls getMembershipState; this mirrors what a real node does and
  ## keeps the seam busy concurrently with foreground calls.
  try:
    let deadline = Moment.now() + s.confirmBudget
    while Moment.now() < deadline:
      await sleepAsync(s.pollInterval)
      let reply = await invokeUnwrap(s, RlnOpGetMembershipState, scopePayload(s))
      if reply.isErr:
        continue
      s.lastPolled = reply.get()
      let st =
        try:
          parseJson(s.lastPolled){"state"}.getStr("")
        except CatchableError:
          ""
      if st notin ["", "pending"]:
        return
  except CancelledError:
    discard

proc rlnconsumerRegisterMembership*(
    c: RlnConsumer, rateLimit: string, optionsJson: string
): Future[Result[string, string]] {.ffi.} =
  ## Async by design: returns the module's immediate reply (normally
  ## state:"pending") and leaves confirmation to the background poller, the
  ## re-emitted membership_state_changed event, and getMembershipState.
  ## optionsJson: {"funding_holding_account_id":...} (direct) or
  ## {"delegated":"true","gifter_peer_id":...,"gifter_multiaddr":...} (gifter).
  let rate = intOr(rateLimit, 0)
  if rate <= 0:
    return err("rateLimit must be a positive integer")
  var payload = scopePayload(c.state)
  payload["rate_limit"] = %rate # JSON integer on the wire — a float reads as 0
  payload["options_json"] = %optionsJson
  let reply = await invokeUnwrap(c.state, RlnOpRegister, payload)
  if reply.isOk:
    let st =
      try:
        parseJson(reply.get()){"state"}.getStr("")
      except CatchableError:
        ""
    if st == "pending":
      asyncSpawn confirmationPoller(c.state)
  return reply

proc rlnconsumerGetMembershipState*(c: RlnConsumer): Future[Result[string, string]] {.ffi.} =
  ## Fresh module read, annotated with the background poller's last sighting.
  let reply = (await invokeUnwrap(c.state, RlnOpGetMembershipState, scopePayload(c.state))).valueOr:
    return err(error)
  try:
    var merged = parseJson(reply)
    if c.state.lastPolled.len > 0:
      merged["consumer_poller"] = parseJson(c.state.lastPolled)
    return ok($merged)
  except CatchableError:
    return ok(reply)

proc rlnconsumerGenerateMessageProof*(
    c: RlnConsumer, payloadHex, contentTopic, timestampSec: string
): Future[Result[string, string]] {.ffi.} =
  ## Builds the signal the way logos-delivery does (payload ++ contentTopic ++
  ## timestamp bytes) and proves over it. Returns {"signal_hex", "proof"} so a
  ## validator can be handed the exact same signal.
  var signalHex: string
  try:
    let ts = uint64(parseBiggestInt(timestampSec.strip()))
    signalHex = bytesToHex(buildSignal(hexToBytes(payloadHex), contentTopic, ts))
  except ValueError as e:
    return err("bad payloadHex/timestamp: " & e.msg)
  var payload = scopePayload(c.state)
  payload["signal_hex"] = %signalHex
  payload["timestamp"] = %timestampSec.strip() # module wants a STRING
  let proof = (await invokeUnwrap(c.state, RlnOpGenerateProof, payload)).valueOr:
    return err(error)
  try:
    return ok($(%*{"signal_hex": signalHex, "proof": parseJson(proof)}))
  except CatchableError as e:
    return err("proof reply not JSON: " & e.msg)

proc rlnconsumerValidateMessageProof*(
    c: RlnConsumer, signalHex, timestampSec, proofJson: string
): Future[Result[string, string]] {.ffi.} =
  ## Seam `verify_proof` (module: validate_proof). Returns the verdict object.
  var payload = scopePayload(c.state)
  payload["signal_hex"] = %signalHex
  payload["timestamp"] = %timestampSec.strip()
  payload["proof_json"] = %proofJson
  return await invokeUnwrap(c.state, RlnOpVerifyProof, payload)

proc rlnconsumerGetEpochQuota*(
    c: RlnConsumer, timestampSec: string
): Future[Result[string, string]] {.ffi.} =
  var payload = scopePayload(c.state)
  payload["timestamp"] = %timestampSec.strip()
  return await invokeUnwrap(c.state, RlnOpGetEpochQuota, payload)

genBindings()
