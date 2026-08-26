#include "rln_module_client.h"

#include <chrono>
#include <cstdio>
#include <memory>
#include <semaphore>

#include <logos_protocol.h> // lp_* C ABI

using nlohmann::json;

namespace {

constexpr const char* kTarget = "liblogos_rln_module";
constexpr const char* kOrigin = "nim_rln_consumer";

json errObj(const std::string& cls, const std::string& kind, const std::string& message)
{
    return json{{"class", cls}, {"kind", kind}, {"message", message}};
}

// Undo up to two levels of string-encoding (the SDK wire's known
// double-encoding quirk): "abc" -> abc, "\"{...}\"" -> {...}.
json unwrapStringLayers(json j)
{
    for (int i = 0; i < 2 && j.is_string(); ++i) {
        auto parsed = json::parse(j.get<std::string>(), nullptr, /*allow_exceptions=*/false);
        if (parsed.is_discarded()) {
            break; // a plain string value, not an encoded document
        }
        j = std::move(parsed);
    }
    return j;
}

// One in-flight async call: the trampoline fills the box and releases the
// semaphore, from the lp client's owner thread. shared_ptr keeps the box
// alive for a late reply after a wait timeout.
struct ReplyBox {
    std::binary_semaphore sem{0};
    bool ok = false;
    std::string json;
};

void replyTrampoline(int ok, const char* jsonText, void* userData)
{
    // Reclaim the heap'd shared_ptr copy; the caller may already be gone.
    std::unique_ptr<std::shared_ptr<ReplyBox>> boxPtr(
        static_cast<std::shared_ptr<ReplyBox>*>(userData));
    auto& box = **boxPtr;
    box.ok = ok != 0;
    if (jsonText) {
        box.json = jsonText;
    }
    box.sem.release();
}

} // namespace

// Box for the event subscription callback (heap'd; freed on unsubscribe).
using MembershipEventFn = std::function<void(const std::string&, const std::string&,
    const std::string&, const std::string&, const std::string&)>;

namespace {
void membershipEventTrampoline(const char* /*eventName*/, const char* dataJson, void* userData)
{
    auto* fn = static_cast<MembershipEventFn*>(userData);
    if (!fn || !dataJson) {
        return;
    }
    json data = json::parse(dataJson, nullptr, /*allow_exceptions=*/false);
    // Payload: [registry_id, rln_identifier, membership_hash, state, previous]
    if (!data.is_array() || data.size() < 5) {
        return;
    }
    auto s = [&data](size_t i) {
        return data[i].is_string() ? data[i].get<std::string>() : std::string();
    };
    (*fn)(s(0), s(1), s(2), s(3), s(4));
}
} // namespace

RlnModuleClient::~RlnModuleClient()
{
    if (m_sub) {
        lp_unsubscribe(m_sub);
    }
    delete static_cast<MembershipEventFn*>(m_subBox);
    if (m_client) {
        lp_client_destroy(m_client);
    }
}

bool RlnModuleClient::subscribeMembershipStateChanged(MembershipEventFn cb)
{
    if (m_sub) {
        return true;
    }
    if (!m_client) {
        return false;
    }
    auto* box = new MembershipEventFn(std::move(cb));
    lp_subscription* sub =
        lp_subscribe(m_client, "membership_state_changed", &membershipEventTrampoline, box);
    if (!sub) {
        delete box;
        return false;
    }
    m_sub = sub;
    m_subBox = box;
    return true;
}

bool RlnModuleClient::init()
{
    if (m_client) {
        return true;
    }
    m_client = lp_client_create(kTarget, kOrigin, nullptr, nullptr);
    if (!m_client) {
        fprintf(stderr, "nim_rln_consumer: lp_client_create failed for %s\n", kTarget);
        return false;
    }
    return true;
}

bool RlnModuleClient::callRaw(const std::string& method, const json& args,
                              int timeoutMs, std::string& raw, RlnModuleResult& fail)
{
    if (!m_client) {
        fail.errorObj = errObj("not_ready", "lp_client_missing",
            method + ": lp client not initialized (install ran off the context thread?)");
        return false;
    }
    auto box = std::make_shared<ReplyBox>();
    auto* handoff = new std::shared_ptr<ReplyBox>(box);
    const std::string argsStr = args.dump();
    const int rc = lp_invoke_async(m_client, method.c_str(), argsStr.c_str(), timeoutMs,
        &replyTrampoline, handoff);
    if (rc != LP_OK) {
        delete handoff; // callback will never fire
        fail.errorObj = errObj("transient", "lp_dispatch_failed",
            method + ": lp_invoke_async rc=" + std::to_string(rc));
        return false;
    }

    // The protocol owns timeout enforcement (timeoutMs above); the margin only
    // guards a callback that never fires (same shape as the Rust modules).
    const auto wait = std::chrono::milliseconds(timeoutMs) + std::chrono::seconds(10);
    if (!box->sem.try_acquire_for(wait)) {
        fail.errorObj = errObj("transient", "lp_reply_timeout",
            method + ": no lp completion within " + std::to_string(timeoutMs) + "ms (+10s)");
        return false;
    }
    if (!box->ok) {
        json err = json::parse(box->json, nullptr, /*allow_exceptions=*/false);
        std::string message = err.is_object() && err.contains("message") && err["message"].is_string()
            ? err["message"].get<std::string>()
            : box->json;
        fail.errorObj = errObj("transient", "lp_error", method + ": " + message);
        return false;
    }
    raw = box->json;
    return true;
}

RlnModuleResult RlnModuleClient::tstr(const std::string& method, const json& args, int timeoutMs)
{
    RlnModuleResult res;
    std::string raw;
    if (!callRaw(method, args, timeoutMs, raw, res)) {
        return res;
    }
    json reply = json::parse(raw, nullptr, /*allow_exceptions=*/false);
    // The dispatch value for a tstr method is a JSON string holding compact
    // JSON; "" is the provider-failure convention.
    if (reply.is_string() && reply.get<std::string>().empty()) {
        res.errorObj = errObj("transient", "provider_failure", method + ": empty reply");
        return res;
    }
    json inner = unwrapStringLayers(std::move(reply));
    if (inner.is_object() && inner.contains("error")) {
        res.errorObj = inner["error"];
        return res;
    }
    if (inner.is_null() || inner.is_discarded()) {
        res.errorObj = errObj("transient", "provider_failure", method + ": unparseable reply: " + raw);
        return res;
    }
    res.ok = true;
    res.value = std::move(inner);
    return res;
}

RlnModuleResult RlnModuleClient::result(const std::string& method, const json& args, int timeoutMs)
{
    RlnModuleResult res;
    std::string raw;
    if (!callRaw(method, args, timeoutMs, raw, res)) {
        return res;
    }
    json envelope = unwrapStringLayers(json::parse(raw, nullptr, /*allow_exceptions=*/false));
    if (!envelope.is_object() || !envelope.contains("success")) {
        res.errorObj = errObj("transient", "bad_envelope",
            method + ": expected result envelope, got: " + raw);
        return res;
    }
    if (!envelope["success"].is_boolean() || !envelope["success"].get<bool>()) {
        // The error arm is a JSON-encoded {class,kind,message} object.
        json errVal = envelope.contains("error") ? envelope["error"] : json();
        json parsed = unwrapStringLayers(errVal);
        res.errorObj = parsed.is_object()
            ? parsed
            : errObj("permanent", "unknown", method + ": " + errVal.dump());
        return res;
    }
    res.ok = true;
    res.value = envelope.contains("value") ? envelope["value"] : json();
    return res;
}
