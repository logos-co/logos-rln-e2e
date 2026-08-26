## RlnConsumer — a Nim mock of logos-delivery's RLN integration, hosted as a
## logos-core module. The C++ plugin drives this library over the nim-ffi C
## ABI; every RLN operation goes out through the mirrored delivery seam
## (rln_seam.nim, typed one-callback-per-function) and comes back from the
## real liblogos_rln_module via the plugin's bridge. See ../../README.md for
## the architecture.
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
    opTimeout: Duration # seam budget; default 10s = delivery's hard limit
    pollInterval: Duration
    confirmBudget: Duration
    lastPolled: string # the confirmation poller's most recent state reply

  RlnConsumer = object
    state: ref ConsumerState # shared across handler copies of the ctx object

declareLibrary("rlnconsumer", RlnConsumer, defaultABIFormat = "c")

type RlnConsumerConfig {.ffi.} = object
  registryId: string # CAIP-10 "logos:<ref>:<64-hex config account>"
  rlnIdentifierHex: string # 64-hex application scope key
  epochSizeSec: string # consumed by the C++ bridge (start scope), not here
  opTimeoutSec: string # default "10" — delivery's hard rlnInvoke budget
  pollIntervalSec: string # default "5"
  confirmBudgetSec: string # default "300"

# ---------------------------------------------------------------- helpers

proc intOr(s: string, fallback: int): int =
  try:
    if s.len == 0: fallback else: parseInt(s)
  except ValueError:
    fallback

proc unwrapEnvelope(res: Result[string, string]): Result[string, string] =
  ## One seam reply. The responder answers the documented envelope
  ## (delivery-module docs/rln.md): {"ok": <op result>} | {"err":
  ## {"kind","message"}} with the LIP's error kinds. A transport timeout
  ## surfaces as the TRANSIENT failure delivery's library synthesizes for
  ## itself at its hard 10s.
  let raw = res.valueOr:
    if error == "timeout":
      return err("""{"kind":"TRANSIENT","message":"seam: timeout"}""")
    return err("seam: " & error)
  try:
    let parsed = parseJson(raw)
    if parsed.kind == JObject and parsed.hasKey("ok"):
      return ok($parsed["ok"])
    if parsed.kind == JObject and parsed.hasKey("err"):
      return err($parsed["err"])
    return err("seam reply is not an ok/err envelope: " & raw)
  except CatchableError as e:
    return err("seam reply not JSON: " & e.msg)

proc lipOptions(rate: int, optionsJson: string): Result[string, string] =
  ## The seam's RegistryOptions encoding (RLN Module API LIP): a key/value
  ## pair array — `rate_limit` is an option key, not a separate argument, and
  ## delivery's bring-up sends exactly this shape. The module-wire options
  ## OBJECT the harness passes ({"funding_holding_account_id":...} or the
  ## delegated set) flattens into it; the bridge maps back to the module's
  ## register(rate_limit, options_object) wire.
  var arr = newJArray()
  arr.add %*{"key": "rate_limit", "value": $rate}
  if optionsJson.strip().len > 0:
    try:
      let obj = parseJson(optionsJson)
      if obj.kind != JObject:
        return err("optionsJson must be a JSON object")
      for k, v in obj:
        arr.add %*{"key": k, "value": (if v.kind == JString: v.getStr else: $v)}
    except CatchableError as e:
      return err("optionsJson not JSON: " & e.msg)
  ok($arr)

proc parseTs(timestampSec: string): Result[uint64, string] =
  ## Unix-seconds string (the CLI's `str:` form) -> the seam's uint64.
  try:
    ok(uint64(parseBiggestInt(timestampSec.strip())))
  except ValueError as e:
    err("bad timestamp: " & e.msg)

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
  ## config.epochSizeSec is not read here: the seam's start op carries no
  ## scope, so the C++ bridge owns the module's start config (it parses the
  ## same createConsumer JSON) — the same out-of-band knowledge a real
  ## responder needs.
  if config.registryId.len == 0 or config.rlnIdentifierHex.len == 0:
    return err("registryId and rlnIdentifierHex are required")
  let s = (ref ConsumerState)(
    registryId: config.registryId,
    rlnIdentifierHex: config.rlnIdentifierHex,
    opTimeout: intOr(config.opTimeoutSec, 10).seconds,
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
  ## Seam `start`. The op carries NO scope (delivery's typed callback is
  ## (req_id) only) — the bridge supplies {epoch_size_sec, registries} from
  ## the createConsumer config, mirroring how any real responder must know
  ## the start scope out of band.
  return unwrapEnvelope(await rlnStart(c.state.opTimeout))

proc rlnconsumerStopRln*(c: RlnConsumer): Future[Result[string, string]] {.ffi.} =
  return unwrapEnvelope(await rlnStop(c.state.opTimeout))

proc confirmationPoller(s: ref ConsumerState) {.async: (raises: []).} =
  ## The delivery-shaped async-registration follow-up: track the membership
  ## out of `pending` in the background. Purely observational — the harness
  ## still polls getMembershipState; this mirrors what a real node does and
  ## keeps the seam busy concurrently with foreground calls.
  try:
    let deadline = Moment.now() + s.confirmBudget
    while Moment.now() < deadline:
      await sleepAsync(s.pollInterval)
      let reply = unwrapEnvelope(
        await rlnGetMembershipState(s.registryId, s.rlnIdentifierHex, s.opTimeout)
      )
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
  ## {"delegated":"true","gifter_peer_id":...,"gifter_multiaddr":...} (gifter)
  ## — flattened into the seam's LIP RegistryOptions key/value array.
  let rate = intOr(rateLimit, 0)
  if rate <= 0:
    return err("rateLimit must be a positive integer")
  let opts = lipOptions(rate, optionsJson).valueOr:
    return err(error)
  let reply = unwrapEnvelope(
    await rlnRegister(c.state.registryId, c.state.rlnIdentifierHex, opts, c.state.opTimeout)
  )
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
  let reply = unwrapEnvelope(
    await rlnGetMembershipState(c.state.registryId, c.state.rlnIdentifierHex, c.state.opTimeout)
  ).valueOr:
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
  let ts = parseTs(timestampSec).valueOr:
    return err(error)
  var signalHex: string
  try:
    signalHex = bytesToHex(buildSignal(hexToBytes(payloadHex), contentTopic, ts))
  except ValueError as e:
    return err("bad payloadHex: " & e.msg)
  let proof = unwrapEnvelope(
    await rlnGenerateProof(
      c.state.registryId, c.state.rlnIdentifierHex, signalHex, ts, c.state.opTimeout
    )
  ).valueOr:
    return err(error)
  try:
    return ok($(%*{"signal_hex": signalHex, "proof": parseJson(proof)}))
  except CatchableError as e:
    return err("proof reply not JSON: " & e.msg)

proc rlnconsumerValidateMessageProof*(
    c: RlnConsumer, signalHex, timestampSec, proofJson: string
): Future[Result[string, string]] {.ffi.} =
  ## Seam `verify_proof` (module: validate_proof). Returns the verdict object.
  let ts = parseTs(timestampSec).valueOr:
    return err(error)
  return unwrapEnvelope(
    await rlnVerifyProof(
      c.state.registryId, c.state.rlnIdentifierHex, signalHex, ts, proofJson,
      c.state.opTimeout,
    )
  )

proc rlnconsumerGetEpochQuota*(
    c: RlnConsumer, timestampSec: string
): Future[Result[string, string]] {.ffi.} =
  let ts = parseTs(timestampSec).valueOr:
    return err(error)
  return unwrapEnvelope(
    await rlnGetEpochQuota(c.state.registryId, c.state.rlnIdentifierHex, ts, c.state.opTimeout)
  )

genBindings()
