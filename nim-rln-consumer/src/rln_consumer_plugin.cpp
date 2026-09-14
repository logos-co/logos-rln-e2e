#include "rln_consumer_plugin.h"

#include <cinttypes>
#include <cstdio>
#include <cstdlib>

#include <nlohmann/json.hpp>

#include "api_call_handler.h" // includes <rlnconsumer.h>, defines the trampolines
#include "rln_seam_bridge.h"

using nlohmann::json;

namespace {

// Case-sensitive string field with a default — the config surface is small
// and owned by this module, no need for delivery's case-insensitive lookup.
std::string strField(const json& j, const char* key, const char* fallback = "")
{
    if (j.is_object() && j.contains(key) && j[key].is_string()) {
        return j[key].get<std::string>();
    }
    return fallback;
}

// The Nim side answers with compact JSON in a string; surface it as a real
// JSON value so CLI consumers (jval) see objects, not escaped strings.
StdLogosResult jsonized(StdLogosResult r)
{
    if (r.success && r.value.is_string()) {
        auto parsed =
            json::parse(r.value.get<std::string>(), nullptr, /*allow_exceptions=*/false);
        if (!parsed.is_discarded()) {
            r.value = std::move(parsed);
        }
    }
    return r;
}

} // namespace

NimRlnConsumerImpl::NimRlnConsumerImpl()
    : consumerCtx(nullptr)
    , bridge(std::make_unique<RlnSeamBridge>())
    , membershipEventSubscribed(false)
{
}

NimRlnConsumerImpl::~NimRlnConsumerImpl()
{
    if (consumerCtx) {
        rlnconsumer_destroy(consumerCtx);
        consumerCtx = nullptr;
    }
}

void NimRlnConsumerImpl::onContextReady()
{
    // The seam must exist before any consumer method fires an op. The event
    // subscription is NOT attempted here: acquiring the source blocks this
    // thread for the transport's full timeout when the RLN module is absent
    // — scenarios opt in via subscribeEvents() once the stack is loaded.
    bridge->install();
}

StdLogosResult NimRlnConsumerImpl::subscribeEvents()
{
    if (membershipEventSubscribed) {
        return {true, {}};
    }
    // Runs on the host's pumping dispatch thread, which is exactly where the
    // subscription must live for lp event delivery.
    membershipEventSubscribed = bridge->subscribeMembershipEvent(
        [this](const std::string& registryId, const std::string& rlnIdentifier,
               const std::string& membershipHash, const std::string& state,
               const std::string& previous) {
            membership_state_changed(registryId, rlnIdentifier, membershipHash, state, previous);
        });
    if (!membershipEventSubscribed) {
        return {false, {}, "membership_state_changed subscription unavailable (is liblogos_rln_module loaded?)"};
    }
    return {true, {}};
}

StdLogosResult NimRlnConsumerImpl::createConsumer(const std::string& cfg)
{
    std::lock_guard<std::mutex> lock(createMutex);
    if (consumerCtx != nullptr) {
        return {false, {}, "consumer already created"};
    }

    json parsed = json::parse(cfg, nullptr, /*allow_exceptions=*/false);
    if (parsed.is_discarded() || !parsed.is_object()) {
        return {false, {}, "createConsumer: config is not a JSON object"};
    }

    // The request struct borrows these strings; they outlive the bound call.
    const std::string registryId = strField(parsed, "registryId");
    const std::string rlnIdentifierHex = strField(parsed, "rlnIdentifierHex");
    const std::string epochSizeSec = strField(parsed, "epochSizeSec", "600");
    const std::string opTimeoutSec = strField(parsed, "opTimeoutSec", "10");
    const std::string registryOpTimeoutSec = strField(parsed, "registryOpTimeoutSec", "95");
    const std::string pollIntervalSec = strField(parsed, "pollIntervalSec", "5");
    const std::string confirmBudgetSec = strField(parsed, "confirmBudgetSec", "300");

    // Since the seam rework the start op carries the module's start config,
    // built Nim-side from this same JSON — the bridge owns no start scope.
    RlnconsumerCreateCtorReq req;
    req.config.registryId = registryId.c_str();
    req.config.rlnIdentifierHex = rlnIdentifierHex.c_str();
    req.config.epochSizeSec = epochSizeSec.c_str();
    req.config.opTimeoutSec = opTimeoutSec.c_str();
    req.config.registryOpTimeoutSec = registryOpTimeoutSec.c_str();
    req.config.pollIntervalSec = pollIntervalSec.c_str();
    req.config.confirmBudgetSec = confirmBudgetSec.c_str();

    // The create callback has the ReplyFn shape with the decimal ctx address
    // as its success text, so the shared ticket bridge serves it too.
    auto outcome = callApiRetValue("createConsumer", CALLBACK_TIMEOUT, [&req](void* ticket) {
        (void)rlnconsumer_create(&req, static_cast<ConsumerReplyFn>(replyTrampoline), ticket);
        return NIMFFI_RET_OK; // dispatch failures surface through the callback
    });
    if (!outcome.success) {
        return outcome;
    }

    // StdLogosResult.value is nlohmann::json; the ticket bridge stored the
    // callback's text (the decimal Nim ctx address) as a JSON string.
    const std::string addrText =
        outcome.value.is_string() ? outcome.value.get<std::string>() : std::string();
    char* endp = nullptr;
    unsigned long long addr = strtoull(addrText.c_str(), &endp, 10);
    if (addrText.empty() || !endp || *endp != '\0' || addr == 0) {
        return {false, {}, "createConsumer: non-numeric context address: " + addrText};
    }
    consumerCtx = reinterpret_cast<void*>(static_cast<uintptr_t>(addr));
    return {true, {}};
}

#define REQUIRE_CONSUMER()                                                                        \
    do {                                                                                          \
        if (!consumerCtx) {                                                                       \
            return {false, {}, "consumer not created - call createConsumer first"};               \
        }                                                                                         \
    } while (0)

StdLogosResult NimRlnConsumerImpl::ping(const std::string& text)
{
    REQUIRE_CONSUMER();
    RlnconsumerPingReq req;
    req.text = text.c_str();
    return callApiRetValue("ping", CALLBACK_TIMEOUT,
        bindApiCall(rlnconsumer_ping, consumerCtx, req));
}

StdLogosResult NimRlnConsumerImpl::slowPing(const std::string& text)
{
    REQUIRE_CONSUMER();
    RlnconsumerSlowPingReq req;
    req.text = text.c_str();
    return callApiRetValue("slowPing", CALLBACK_TIMEOUT,
        bindApiCall(rlnconsumer_slow_ping, consumerCtx, req));
}

StdLogosResult NimRlnConsumerImpl::startRln()
{
    REQUIRE_CONSUMER();
    return jsonized(callApiRetValue("startRln", CALLBACK_TIMEOUT,
        bindScalarApiCall(rlnconsumer_start_rln, consumerCtx)));
}

StdLogosResult NimRlnConsumerImpl::stopRln()
{
    REQUIRE_CONSUMER();
    return jsonized(callApiRetValue("stopRln", CALLBACK_TIMEOUT,
        bindScalarApiCall(rlnconsumer_stop_rln, consumerCtx)));
}

StdLogosResult NimRlnConsumerImpl::registerMembership(
    const std::string& rateLimit, const std::string& optionsJson)
{
    REQUIRE_CONSUMER();
    RlnconsumerRegisterMembershipReq req;
    req.rateLimit = rateLimit.c_str();
    req.optionsJson = optionsJson.c_str();
    return jsonized(callApiRetValue("registerMembership", CALLBACK_TIMEOUT,
        bindApiCall(rlnconsumer_register_membership, consumerCtx, req)));
}

StdLogosResult NimRlnConsumerImpl::getMembershipState()
{
    REQUIRE_CONSUMER();
    return jsonized(callApiRetValue("getMembershipState", CALLBACK_TIMEOUT,
        bindScalarApiCall(rlnconsumer_get_membership_state, consumerCtx)));
}

StdLogosResult NimRlnConsumerImpl::generateMessageProof(
    const std::string& payloadHex, const std::string& contentTopic, const std::string& timestampSec)
{
    REQUIRE_CONSUMER();
    RlnconsumerGenerateMessageProofReq req;
    req.payloadHex = payloadHex.c_str();
    req.contentTopic = contentTopic.c_str();
    req.timestampSec = timestampSec.c_str();
    return jsonized(callApiRetValue("generateMessageProof", CALLBACK_TIMEOUT,
        bindApiCall(rlnconsumer_generate_message_proof, consumerCtx, req)));
}

StdLogosResult NimRlnConsumerImpl::validateMessageProof(
    const std::string& signalHex, const std::string& timestampSec, const std::string& proofJson)
{
    REQUIRE_CONSUMER();
    RlnconsumerValidateMessageProofReq req;
    req.signalHex = signalHex.c_str();
    req.timestampSec = timestampSec.c_str();
    req.proofJson = proofJson.c_str();
    return jsonized(callApiRetValue("validateMessageProof", CALLBACK_TIMEOUT,
        bindApiCall(rlnconsumer_validate_message_proof, consumerCtx, req)));
}

StdLogosResult NimRlnConsumerImpl::getEpochQuota(const std::string& timestampSec)
{
    REQUIRE_CONSUMER();
    RlnconsumerGetEpochQuotaReq req;
    req.timestampSec = timestampSec.c_str();
    return jsonized(callApiRetValue("getEpochQuota", CALLBACK_TIMEOUT,
        bindApiCall(rlnconsumer_get_epoch_quota, consumerCtx, req)));
}
