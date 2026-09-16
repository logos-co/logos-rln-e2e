/* The RLN module seam, mirrored from logos-delivery's
 * library/liblogosdelivery_rln.h (branch impl-plugable-rln-api-module
 * rebased onto feat/rln-api-structure — the rln/integration-fixes stack,
 * refreshed 2026-08-28) with the prefix renamed. The op set and types
 * match delivery's client-facing RlnInterface (waku/rln/rln.nim +
 * waku/rln/types.nim — 7 ops, scope on every call, uint64-seconds
 * timestamps, 4 verdicts, 9 statuses, 4 error kinds). Scalar args cross
 * directly; complex args (config, options, proof) and every result are
 * JSON strings.
 *
 * Since the seam rework (delivery's 95e7e3c7) results follow the RLN
 * module's OWN wire dialects, forwarded verbatim — the ok/err envelope is
 * retired:
 * - start/stop/generate_proof/validate_proof/get_epoch_quota answer with
 *   the module's LogosResult envelope {"success":bool,"value":…,"error":…}
 *   where a failure's error is the JSON-encoded typed object
 *   {"class":…,"kind":…,"message":…} (class: not_ready | transient |
 *   budget_exhausted | permanent).
 * - register_membership/get_membership_state answer with the module's
 *   compact JSON reply; failures are the in-band envelope
 *   {"error":{"class":…,…}}.
 * The op and the RLN module method are both named `validate_proof` — one
 * name end to end. All strings are borrowed for the duration of the call —
 * copy before returning. */
#pragma once
#ifndef __rlnconsumer_rln__
#define __rlnconsumer_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* config_json is the RLN module's start() config — at minimum
   {"epoch_size_sec":N}, plus "registries" to warm — built by the library
   from its own configuration and passed to the module verbatim. */
typedef void (*RlnConsumerRlnStartFn)(uint64_t req_id, const char* config_json,
                                      void* user_data);

typedef void (*RlnConsumerRlnStopFn)(uint64_t req_id, void* user_data);

typedef void (*RlnConsumerRlnRegisterFn)(uint64_t req_id, const char* registry_id,
                                         const char* rln_identifier,
                                         const char* options_json, void* user_data);

typedef void (*RlnConsumerRlnGetMembershipStateFn)(uint64_t req_id,
                                                   const char* registry_id,
                                                   const char* rln_identifier,
                                                   void* user_data);

typedef void (*RlnConsumerRlnGetEpochQuotaFn)(uint64_t req_id, const char* registry_id,
                                              const char* rln_identifier,
                                              uint64_t timestamp, void* user_data);

typedef void (*RlnConsumerRlnGenerateProofFn)(uint64_t req_id, const char* registry_id,
                                              const char* rln_identifier,
                                              const char* signal_hex,
                                              uint64_t timestamp, void* user_data);

typedef void (*RlnConsumerRlnValidateProofFn)(uint64_t req_id, const char* registry_id,
                                            const char* rln_identifier,
                                            const char* signal_hex, uint64_t timestamp,
                                            const char* proof_json, void* user_data);

typedef struct {
  RlnConsumerRlnStartFn start;
  RlnConsumerRlnStopFn stop;
  RlnConsumerRlnRegisterFn register_membership; /* "register" is a C++ keyword-adjacent trap */
  RlnConsumerRlnGetMembershipStateFn get_membership_state;
  RlnConsumerRlnGetEpochQuotaFn get_epoch_quota;
  RlnConsumerRlnGenerateProofFn generate_proof;
  RlnConsumerRlnValidateProofFn validate_proof;
} RlnConsumerRlnCallbacks;

/* library ← shell: register once, before any consumer method. NULL clears and
   fails all in-flight requests. Returns 0 on success. */
int rlnconsumer_rln_set_callbacks(const RlnConsumerRlnCallbacks* cbs,
                                  void* user_data);

/* shell → library: completion of an outbound call, same req_id. Thread-safe;
   result_json is copied before return. */
int rlnconsumer_rln_response(uint64_t req_id, const char* result_json);

#ifdef __cplusplus
}
#endif
#endif
