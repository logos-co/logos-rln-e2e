#pragma once

#include <chrono>
#include <memory>
#include <mutex>
#include <string>

#include <logos_module_context.h>
#include <logos_result.h>

class RlnSeamBridge;

/**
 * @brief Nim mock of logos-delivery's RLN integration, for acceptance tests.
 *
 * The module sandwiches every RLN operation through the layers logos-delivery
 * will use in production: harness call -> this plugin -> librlnconsumer (Nim,
 * nim-ffi C ABI) -> the mirrored delivery RLN seam (rlnconsumer_rln.h,
 * 7 opaque-JSON op callbacks) -> this plugin's seam bridge -> lp wire ->
 * liblogos_rln_module.
 *
 * Lifecycle contract:
 * - call @ref createConsumer exactly once per context
 * - call @ref startRln before proof operations
 * - @ref registerMembership is ASYNC BY DESIGN: it returns the RLN module's
 *   immediate reply (normally `state:"pending"`); activation is observed via
 *   @ref getMembershipState polling and the re-emitted
 *   `membership_state_changed` event — never a long-blocking call.
 *
 * The seam op `verify_proof` (delivery's name) maps to the RLN module method
 * `validate_proof` (its 0.5.0 name) inside the bridge.
 */
class NimRlnConsumerImpl : public LogosModuleContext
{
public:
    NimRlnConsumerImpl();
    ~NimRlnConsumerImpl();

    /**
     * @brief Creates the Nim RlnConsumer bound to one RLN scope.
     *
     * @param cfg UTF-8 JSON object: {"registryId": "logos:<ref>:<64-hex>",
     *   "rlnIdentifierHex": "<64-hex>", "epochSizeSec"?: "600",
     *   "opTimeoutSec"?: "30", "pollIntervalSec"?: "5",
     *   "confirmBudgetSec"?: "300"}. All values are strings.
     *   `opTimeoutSec:"10"` reproduces logos-delivery's hard rlnInvoke limit.
     * @return success with an empty value, or the Nim-side error.
     */
    StdLogosResult createConsumer(const std::string& cfg);

    /** @brief Seam `start`: configure epoch size, warm the registry roots. */
    StdLogosResult startRln();

    /** @brief Seam `stop`. */
    StdLogosResult stopRln();

    /**
     * @brief Register a membership for the consumer's scope. Async by design:
     * replies with the module's immediate view (normally `state:"pending"`).
     *
     * @param rateLimit Positive integer, as a string.
     * @param optionsJson `{"funding_holding_account_id":"<acct>"}` (direct) or
     *   `{"delegated":"true","gifter_peer_id":...,"gifter_multiaddr":...}`.
     * @return the public membership view JSON.
     */
    StdLogosResult registerMembership(const std::string& rateLimit, const std::string& optionsJson);

    /** @brief Fresh membership state for the scope (module read), annotated
     *  with the Nim confirmation poller's last sighting. */
    StdLogosResult getMembershipState();

    /**
     * @brief Build a delivery-shaped signal (payload ++ contentTopic ++
     * timestamp bytes) and generate a proof over it.
     * @return {"signal_hex":..., "proof":{...}} — hand signal_hex to a validator.
     */
    StdLogosResult generateMessageProof(
        const std::string& payloadHex,
        const std::string& contentTopic,
        const std::string& timestampSec);

    /** @brief Validate a proof (seam `verify_proof` -> module `validate_proof`).
     *  @return the verdict object, e.g. {"verdict":"valid"}. */
    StdLogosResult validateMessageProof(
        const std::string& signalHex,
        const std::string& timestampSec,
        const std::string& proofJson);

    /** @brief The scope's rate-limit budget for the timestamp's epoch. */
    StdLogosResult getEpochQuota(const std::string& timestampSec);

    /**
     * @brief Subscribe to the RLN module's membership_state_changed and
     * re-emit it as this module's own event.
     *
     * Explicit rather than automatic: acquiring the event source blocks the
     * dispatch thread for the transport's full timeout when
     * liblogos_rln_module is not loaded, so only a scenario that loads the
     * RLN stack should call this (before registerMembership — a late
     * subscribe can miss the transition; chat-module's lesson).
     */
    StdLogosResult subscribeEvents();

    /** @brief Selftest liveness probe: proves the plugin -> Nim leg. */
    StdLogosResult ping(const std::string& text);

    /** @brief Selftest probe that crosses one nim-ffi RET_STALE_WARN tick
     *  (~5s): proves the ticket bridge treats the tick as non-terminal. */
    StdLogosResult slowPing(const std::string& text);

    std::string name() const { return "nim_rln_consumer"; }

logos_events:
    /** Re-emission of liblogos_rln_module's membership_state_changed. */
    void membership_state_changed(
        const std::string& registry_id,
        const std::string& rln_identifier,
        const std::string& membership_hash,
        const std::string& state,
        const std::string& previous);

protected:
    void onContextReady() override;

private:
    // The Nim consumer ctx (nim-ffi handle), nullptr until createConsumer.
    void* consumerCtx;
    std::mutex createMutex;

    // The seam bridge: owns the worker thread serving the 7 RLN op callbacks
    // and the lp client to liblogos_rln_module. Held via pointer so the C
    // headers stay out of this codegen-scanned header.
    std::unique_ptr<RlnSeamBridge> bridge;

    bool membershipEventSubscribed;

    static constexpr std::chrono::seconds CALLBACK_TIMEOUT{60};
};
