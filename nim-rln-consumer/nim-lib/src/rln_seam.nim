## The RLN module seam, mirrored from logos-delivery so the e2e exercises the
## exact contract delivery is building (logos-delivery branch
## impl-plugable-rln-api-module + the rln/integration-fixes stack:
## library/logos_delivery_api/rln_api.nim + library/liblogosdelivery_rln.h,
## refreshed 2026-08-28 — the rebased rln/integration-fixes stack: typed
## one-callback-per-function surface, validate_proof name, start carrying
## the module's start config). The op set and types match delivery's
## client-facing RlnInterface concept (feat/rln-api-structure:
## waku/rln/rln.nim + waku/rln/types.nim). Scalar args are passed directly,
## complex args (config, options, proof) as JSON, and every call's result
## comes back as JSON via `rlnconsumer_rln_response` — the RLN module's OWN
## reply, forwarded verbatim (the ok/err envelope is retired since
## delivery's 95e7e3c7): the LogosResult envelope for result-dialect ops,
## the compact tstr reply (in-band {"error":{...}}) for register /
## get_membership_state. rlnconsumer.nim owns the dialect parsing, exactly
## as delivery's rln_api.nim does.
##
## ONE deliberate divergence from delivery: every outbound proc takes a
## timeout (delivery hardcodes its per-op budgets — 95s registry reads, 10s
## local) so scenarios can probe other budgets. See README.md "Findings for the delivery team".
##
## Threading: host callbacks may complete on a foreign thread, so the
## crossing uses `ThreadSignalPtr` + `allocShared` (no GC memory shared
## across threads). One `Lock` guards the callback table and the in-flight
## `ptr Pending` list.

import std/locks
import chronos, chronos/threadsync, results

const
  SeamLocalTimeout* = 10.seconds ## delivery's budget for local-computation ops
  SeamRegistryReadTimeout* = 95.seconds ## delivery's budget for ops that may
                                        ## perform one registry read (register,
                                        ## get_membership_state, generate_proof)
  SeamDefaultTimeout* = SeamLocalTimeout

type
  RlnConsumerRlnStartFn = proc(
    reqId: uint64, configJson: cstring, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnStopFn =
    proc(reqId: uint64, userData: pointer) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnRegisterFn = proc(
    reqId: uint64, registryId, rlnIdentifier, optionsJson: cstring, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnGetMembershipStateFn = proc(
    reqId: uint64, registryId, rlnIdentifier: cstring, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnGetEpochQuotaFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier: cstring,
    timestamp: uint64,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnGenerateProofFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnValidateProofFn = proc(
    reqId: uint64,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    proofJson: cstring,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].}

  RlnConsumerRlnCallbacks = object
    start: RlnConsumerRlnStartFn
    stop: RlnConsumerRlnStopFn
    register_membership: RlnConsumerRlnRegisterFn
    get_membership_state: RlnConsumerRlnGetMembershipStateFn
    get_epoch_quota: RlnConsumerRlnGetEpochQuotaFn
    generate_proof: RlnConsumerRlnGenerateProofFn
    validate_proof: RlnConsumerRlnValidateProofFn ## one name end to end
                                                  ## (delivery renamed natively
                                                  ## in 95e7e3c7)

  Pending = object
    reqId: uint64
    signal: ThreadSignalPtr # how the awaiting call gets woken
    resultBuf: cstring # allocShared copy of the host's JSON result; nil until answered
    completed: bool
    next: ptr Pending # intrusive in-flight list — no GC memory, cross-thread safe

var
  gLock: Lock
  gCallbacks: RlnConsumerRlnCallbacks # all-nil struct = "not registered"
  gUserData: pointer
  gPending: ptr Pending # head of the in-flight request list
  gNextReqId: uint64

initLock(gLock)

# --- transport primitives -----------------------------------------------------

proc newPending(): ptr Pending =
  ## Allocate a pending node with a fresh signal. nil on signal-alloc failure.
  let p = cast[ptr Pending](allocShared0(sizeof(Pending)))
  p.signal = ThreadSignalPtr.new().valueOr:
    deallocShared(p)
    return nil
  p

proc linkPending(p: ptr Pending) =
  ## Assign `p` a req id and link it into the in-flight list. Caller holds gLock.
  p.reqId = gNextReqId
  inc gNextReqId
  p.next = gPending
  gPending = p

proc unlinkPending(target: ptr Pending) =
  ## Remove `target` from the in-flight list. Caller holds gLock. Safe if unlinked.
  if gPending == target:
    gPending = target.next
    return
  var p = gPending
  while not p.isNil and p.next != target:
    p = p.next
  if not p.isNil:
    p.next = target.next

proc awaitResult(
    p: ptr Pending, timeout: Duration
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  ## Await the host's response for an already-registered node; always unlinks +
  ## frees. Divergence: the timeout is a parameter — delivery hardcodes
  ## 10.seconds here and synthesizes the failure itself.
  defer:
    withLock gLock:
      unlinkPending(p)
    discard p.signal.close()
    if not p.resultBuf.isNil:
      deallocShared(p.resultBuf)
    deallocShared(p)

  let answered = await p.signal.wait().withTimeout(timeout)
  if not answered or not p.completed:
    return
      err("timeout") # or "module cleared" if completed=false via set_callbacks(nil)
  return ok($p.resultBuf) # Nim string materialized here, on the chronos thread — safe

# --- outbound calls (one per RLN function) ------------------------------------
# Each: allocate + register a pending node, capture its callback + userData under
# the lock, fire the callback (outside the lock, so a synchronous host response
# can't deadlock), then await the JSON result.

proc rlnStart*(
    configJson: string, timeout = SeamLocalTimeout
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnStartFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.start
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, configJson.cstring, ud)
  return await awaitResult(pending, timeout)

proc rlnStop*(
    timeout = SeamDefaultTimeout
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnStopFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.stop
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, ud)
  return await awaitResult(pending, timeout)

proc rlnRegister*(
    registryId, rlnIdentifier, optionsJson: string, timeout = SeamDefaultTimeout
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnRegisterFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.register_membership
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, registryId.cstring, rlnIdentifier.cstring, optionsJson.cstring, ud)
  return await awaitResult(pending, timeout)

proc rlnGetMembershipState*(
    registryId, rlnIdentifier: string, timeout = SeamDefaultTimeout
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnGetMembershipStateFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.get_membership_state
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, registryId.cstring, rlnIdentifier.cstring, ud)
  return await awaitResult(pending, timeout)

proc rlnGetEpochQuota*(
    registryId, rlnIdentifier: string, timestamp: uint64, timeout = SeamDefaultTimeout
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnGetEpochQuotaFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.get_epoch_quota
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(pending.reqId, registryId.cstring, rlnIdentifier.cstring, timestamp, ud)
  return await awaitResult(pending, timeout)

proc rlnGenerateProof*(
    registryId, rlnIdentifier, signalHex: string,
    timestamp: uint64,
    timeout = SeamDefaultTimeout,
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnGenerateProofFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.generate_proof
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(
    pending.reqId, registryId.cstring, rlnIdentifier.cstring, signalHex.cstring,
    timestamp, ud,
  )
  return await awaitResult(pending, timeout)

proc rlnValidateProof*(
    registryId, rlnIdentifier, signalHex: string,
    timestamp: uint64,
    proofJson: string,
    timeout = SeamDefaultTimeout,
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let pending = newPending()
  if pending.isNil:
    return err("signal alloc failed")
  var cb: RlnConsumerRlnValidateProofFn
  var ud: pointer
  withLock gLock:
    cb = gCallbacks.validate_proof
    if cb.isNil:
      discard pending.signal.close()
      deallocShared(pending)
      return err("RLN module not registered")
    ud = gUserData
    linkPending(pending)
  cb(
    pending.reqId, registryId.cstring, rlnIdentifier.cstring, signalHex.cstring,
    timestamp, proofJson.cstring, ud,
  )
  return await awaitResult(pending, timeout)

# --- C entry points -----------------------------------------------------------

#int rlnconsumer_rln_set_callbacks(const RlnConsumerRlnCallbacks* cbs, void* user_data);
proc rlnconsumer_rln_set_callbacks(
    cbs: ptr RlnConsumerRlnCallbacks, userData: pointer
): cint {.exportc, cdecl, dynlib.} =
  # copy struct (or clear on nil), stash userData; nil fails all pending
  withLock gLock:
    if cbs.isNil:
      gCallbacks = RlnConsumerRlnCallbacks()
      gUserData = nil
      var p = gPending
      while not p.isNil:
        p.completed = false # signals "module cleared", not a real completion
        discard p.signal.fireSync()
        p = p.next
    else:
      gCallbacks = cbs[]
      gUserData = userData
    return 0

#int rlnconsumer_rln_response(uint64_t req_id, const char* result_json);
proc rlnconsumer_rln_response(
    reqId: uint64, resultJson: cstring
): cint {.exportc, cdecl, dynlib.} =
  # under lock: find pending by reqId, copy the JSON in, fireSync the signal.
  # unknown reqId → non-zero (late response after timeout)
  withLock gLock:
    var p = gPending
    while not p.isNil and p.reqId != reqId:
      p = p.next
    if p.isNil:
      return 1
    let n = resultJson.len()
    p.resultBuf = cast[cstring](allocShared0(n + 1)) # shared heap: safe on any thread
    copyMem(p.resultBuf, resultJson, n)
    p.completed = true
    discard p.signal.fireSync()
    return 0
