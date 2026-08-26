/* The RLN module seam, mirrored from logos-delivery's
 * library/liblogosdelivery_rln.h (branch impl-plugable-rln-api-module,
 * 2026-08-25) with the prefix renamed. Opaque JSON in/out — the host module
 * owns the payload schema. Op names are delivery's; the host maps
 * `verify_proof` to the RLN module's `validate_proof` method. */
#pragma once
#ifndef __rlnconsumer_rln__
#define __rlnconsumer_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*RlnConsumerRlnOpFn)(uint64_t req_id, const char* payload_json,
                                   void* user_data);

typedef struct {
  RlnConsumerRlnOpFn start;
  RlnConsumerRlnOpFn stop;
  RlnConsumerRlnOpFn register_membership; /* "register" is a C++ keyword-adjacent trap */
  RlnConsumerRlnOpFn get_membership_state;
  RlnConsumerRlnOpFn get_epoch_quota;
  RlnConsumerRlnOpFn generate_proof;
  RlnConsumerRlnOpFn verify_proof;
} RlnConsumerRlnCallbacks;

/* library ← shell: register once, before any consumer method. NULL clears and
   fails all in-flight requests. Returns 0 on success. */
int rlnconsumer_rln_set_callbacks(const RlnConsumerRlnCallbacks* cbs,
                                  void* user_data);

/* shell → library: completion of an outbound call. Thread-safe; the string
   is copied before return. */
int rlnconsumer_rln_response(uint64_t req_id, const char* result_json);

#ifdef __cplusplus
}
#endif
#endif
