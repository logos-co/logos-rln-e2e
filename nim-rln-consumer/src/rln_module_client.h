#pragma once

// Client for liblogos_rln_module over the raw lp_* consumer ABI, shaped like
// the Rust modules' own cross-module clients (e.g. the membership module's
// provider.rs): the lp client is created ONCE on the host's pumping main
// thread (init(), from onContextReady), and every call from the bridge's
// worker thread uses lp_invoke_async + a semaphore wait — async completions
// are delivered from the client's owner thread whenever it pumps.
//
// Why not logos::LpClient's sync invoke from the worker: a plain std::thread
// runs no Qt event loop, so a client owned by it never receives replies —
// the M2 run proved a sync invoke from the worker hangs indefinitely.
//
// Reply dialects carried here (logos-rln-modules docs/wire-binding.md):
// - `tstr` methods: a JSON string of compact JSON; in-band
//   {"error":{class,kind,message}}; "" = provider failure.
// - `result` methods: {"success","value","error"}, `error` a JSON-encoded
//   {class,kind,message}. Both possibly double-encoded.

#include <cstdint>
#include <functional>
#include <string>

#include <nlohmann/json.hpp>

struct lp_client;
struct lp_subscription;

struct RlnModuleResult {
    bool ok = false;
    nlohmann::json value;    // the reply value on ok
    nlohmann::json errorObj; // {class,kind,message}-shaped on failure
};

struct RlnModuleRaw {
    bool ok = false;
    std::string text;        // the module's reply VERBATIM (one JSON-string
                             // transport layer removed for tstr methods)
    nlohmann::json errorObj; // {class,kind,message}-shaped transport failure
};

class RlnModuleClient {
public:
    RlnModuleClient() = default;
    ~RlnModuleClient();
    RlnModuleClient(const RlnModuleClient&) = delete;
    RlnModuleClient& operator=(const RlnModuleClient&) = delete;

    // Create the lp client. MUST run on a thread that keeps pumping a Qt
    // event loop for the process lifetime (the module context thread) —
    // async replies are delivered from it.
    bool init();

    // Positional-args calls, safe from any thread once init() ran.
    RlnModuleResult tstr(const std::string& method, const nlohmann::json& args,
                         int timeoutMs);
    RlnModuleResult result(const std::string& method, const nlohmann::json& args,
                           int timeoutMs);

    // The module's reply text verbatim, either dialect — what a seam
    // responder forwards since the rework retired the ok/err envelope. Only
    // transport failures are synthesized (errorObj); the module's own
    // failures stay inside `text` in the module's shape.
    RlnModuleRaw raw(const std::string& method, const nlohmann::json& args,
                     int timeoutMs);

    // Subscribe to the module's membership_state_changed (5-string payload).
    // Rides the SAME main-owned client, so event delivery has a pumping
    // owner regardless of which thread calls this. Idempotent-ish: one
    // subscription per client; returns false without a client or on failure.
    bool subscribeMembershipStateChanged(
        std::function<void(const std::string&, const std::string&, const std::string&,
                           const std::string&, const std::string&)> cb);

private:
    // One lp round-trip; fills `raw` with the result JSON text on success.
    bool callRaw(const std::string& method, const nlohmann::json& args,
                 int timeoutMs, std::string& raw, RlnModuleResult& fail);

    lp_client* m_client = nullptr;
    lp_subscription* m_sub = nullptr;
    void* m_subBox = nullptr;
};
