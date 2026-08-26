/* The RLN module seam, mirrored from logos-delivery's
 * library/liblogosdelivery_rln.h (branch impl-plugable-rln-api-module,
 * refreshed 2026-08-26 — the typed one-callback-per-function surface) with
 * the prefix renamed. Scalar args cross directly; complex args (options,
 * proof) and every result are JSON strings. Results use the reply envelope
 * {"ok": <result>} | {"err": {"kind","message"}} (delivery-module
 * docs/rln.md). Op names are delivery's; the host maps `verify_proof` to
 * the RLN module's `validate_proof` method. All strings are borrowed for
 * the duration of the call — copy before returning. */
#pragma once
#ifndef __rlnconsumer_rln__
#define __rlnconsumer_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*RlnConsumerRlnStartFn)(uint64_t req_id, void* user_data);

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

typedef void (*RlnConsumerRlnVerifyProofFn)(uint64_t req_id, const char* registry_id,
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
  RlnConsumerRlnVerifyProofFn verify_proof;
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
