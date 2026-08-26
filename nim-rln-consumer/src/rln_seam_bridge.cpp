#include "rln_seam_bridge.h"

#include <cstdio>
#include <cstdlib>

#include <nlohmann/json.hpp>

extern "C" {
#include <rlnconsumer_rln.h>
}

using nlohmann::json;

namespace {

std::string toStringOrEmpty(const char* s)
{
    return s ? s : "";
}

// The envelope every responder must speak (delivery-module docs/rln.md).
std::string makeOk(const json& value)
{
    return json{{"ok", value}}.dump();
}

std::string makeErr(const std::string& kind, const std::string& message)
{
    return json{{"err", {{"kind", kind}, {"message", message}}}}.dump();
}

// Mechanical map from the module's {class,kind,message} error onto the LIP's
// four kinds. No semantic reinterpretation: verdicts (invalid/duplicate/...)
// are module SUCCESS values and never come through here.
std::string lipKind(const json& errorObj)
{
    auto field = [&errorObj](const char* k) {
        return errorObj.contains(k) && errorObj[k].is_string()
            ? errorObj[k].get<std::string>()
            : std::string();
    };
    const std::string kind = field("kind");
    const std::string cls = field("class");
    if (kind == "not_ready") {
        return "NOT_READY";
    }
    if (kind == "budget_exhausted" || kind == "quota_exhausted") {
        return "BUDGET_EXHAUSTED";
    }
    if (kind == "transient" || kind == "provider_failure" || cls == "transient") {
        return "TRANSIENT";
    }
    return "PERMANENT";
}

std::string makeModuleErr(const json& errorObj)
{
    std::string msg = errorObj.contains("message") && errorObj["message"].is_string()
        ? errorObj["message"].get<std::string>()
        : errorObj.dump();
    return makeErr(lipKind(errorObj), msg);
}

} // namespace

RlnSeamBridge::RlnSeamBridge() = default;

RlnSeamBridge::~RlnSeamBridge()
{
    if (m_installed) {
        // Clear the seam first: fails all in-flight calls cleanly.
        rlnconsumer_rln_set_callbacks(nullptr, nullptr);
    }
    {
        std::lock_guard<std::mutex> lock(m_lock);
        m_stopping = true;
    }
    m_cv.notify_all();
    if (m_worker.joinable()) {
        m_worker.join();
    }
}

void RlnSeamBridge::install()
{
    if (m_installed) {
        return;
    }
    // Main thread, pre-pump: makes main the lp client's owner (see header).
    if (!m_rln.init()) {
        fprintf(stderr, "nim_rln_consumer: lp client init failed — RLN ops will error\n");
    }
    m_worker = std::thread(&RlnSeamBridge::workerLoop, this);

    RlnConsumerRlnCallbacks cbs;
    cbs.start = &RlnSeamBridge::startTrampoline;
    cbs.stop = &RlnSeamBridge::stopTrampoline;
    cbs.register_membership = &RlnSeamBridge::registerTrampoline;
    cbs.get_membership_state = &RlnSeamBridge::getStateTrampoline;
    cbs.get_epoch_quota = &RlnSeamBridge::getQuotaTrampoline;
    cbs.generate_proof = &RlnSeamBridge::generateTrampoline;
    cbs.verify_proof = &RlnSeamBridge::verifyTrampoline;
    rlnconsumer_rln_set_callbacks(&cbs, this);
    m_installed = true;
}

void RlnSeamBridge::setStartScope(const std::string& registryId,
                                  const std::string& epochSizeSec)
{
    std::lock_guard<std::mutex> lock(m_lock);
    m_startRegistryId = registryId;
    m_startEpochSizeSec = epochSizeSec;
}

void RlnSeamBridge::enqueue(Job job)
{
    // Runs on the Nim chronos thread — return immediately, never call the
    // module here. The borrowed strings were copied by the trampoline.
    {
        std::lock_guard<std::mutex> lock(m_lock);
        m_queue.push_back(std::move(job));
    }
    m_cv.notify_one();
}

// --- typed trampolines (seam contract: copy the borrowed strings, queue, return)

void RlnSeamBridge::startTrampoline(uint64_t reqId, void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Start;
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::stopTrampoline(uint64_t reqId, void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Stop;
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::registerTrampoline(uint64_t reqId, const char* registryId,
                                       const char* rlnIdentifier, const char* optionsJson,
                                       void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Register;
    j.registryId = toStringOrEmpty(registryId);
    j.rlnIdentifier = toStringOrEmpty(rlnIdentifier);
    j.optionsJson = toStringOrEmpty(optionsJson);
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::getStateTrampoline(uint64_t reqId, const char* registryId,
                                       const char* rlnIdentifier, void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::GetState;
    j.registryId = toStringOrEmpty(registryId);
    j.rlnIdentifier = toStringOrEmpty(rlnIdentifier);
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::getQuotaTrampoline(uint64_t reqId, const char* registryId,
                                       const char* rlnIdentifier, uint64_t timestamp,
                                       void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::GetQuota;
    j.registryId = toStringOrEmpty(registryId);
    j.rlnIdentifier = toStringOrEmpty(rlnIdentifier);
    j.timestamp = timestamp;
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::generateTrampoline(uint64_t reqId, const char* registryId,
                                       const char* rlnIdentifier, const char* signalHex,
                                       uint64_t timestamp, void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Generate;
    j.registryId = toStringOrEmpty(registryId);
    j.rlnIdentifier = toStringOrEmpty(rlnIdentifier);
    j.signalHex = toStringOrEmpty(signalHex);
    j.timestamp = timestamp;
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::verifyTrampoline(uint64_t reqId, const char* registryId,
                                     const char* rlnIdentifier, const char* signalHex,
                                     uint64_t timestamp, const char* proofJson,
                                     void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Verify;
    j.registryId = toStringOrEmpty(registryId);
    j.rlnIdentifier = toStringOrEmpty(rlnIdentifier);
    j.signalHex = toStringOrEmpty(signalHex);
    j.timestamp = timestamp;
    j.proofJson = toStringOrEmpty(proofJson);
    static_cast<RlnSeamBridge*>(userData)->enqueue(std::move(j));
}

void RlnSeamBridge::workerLoop()
{
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(m_lock);
            m_cv.wait(lock, [&] { return m_stopping || !m_queue.empty(); });
            if (m_stopping) {
                return;
            }
            job = std::move(m_queue.front());
            m_queue.pop_front();
        }
        std::string out;
        try {
            out = serveOp(job);
        } catch (const std::exception& e) {
            out = makeErr("PERMANENT", std::string("bridge exception: ") + e.what());
        }
        // Late replies (Nim side timed out) return non-zero; nothing to do.
        rlnconsumer_rln_response(job.reqId, out.c_str());
    }
}

std::string RlnSeamBridge::serveOp(const Job& job)
{
    // lp timeouts mirror the module's own internal legs (membership module
    // provider.rs: reads 70s, register submit 190s). The Nim seam's timeout
    // (delivery's 10s by default) is usually the binding constraint; a late
    // completion here just gets dropped by rlnconsumer_rln_response (rc 1).
    constexpr int kReadMs = 70'000;
    constexpr int kRegisterMs = 190'000;

    const std::string ts = std::to_string(job.timestamp); // module wants a STRING

    RlnModuleResult r;
    switch (job.op) {
    case Op::Start: {
        // The seam's start carries no scope: serve it from the bridge-owned
        // config (set at createConsumer).
        std::string registry, epoch;
        {
            std::lock_guard<std::mutex> lock(m_lock);
            registry = m_startRegistryId;
            epoch = m_startEpochSizeSec;
        }
        if (registry.empty()) {
            return makeErr("NOT_READY", "start scope not configured (createConsumer first)");
        }
        long long epochSec = strtoll(epoch.c_str(), nullptr, 10);
        if (epochSec <= 0) {
            epochSec = 600;
        }
        const json cfg{{"epoch_size_sec", epochSec}, {"registries", json::array({registry})}};
        r = m_rln.result("start", json::array({cfg.dump()}), kReadMs);
        break;
    }
    case Op::Stop:
        r = m_rln.result("stop", json::array(), kReadMs);
        break;
    case Op::Register: {
        // optionsJson is the LIP RegistryOptions key/value array (rate_limit
        // is an option key). The module's wire predates that shape:
        // register(registry_id, rln_identifier, rate_limit i64, options
        // OBJECT) — map array -> (rate, object) here.
        json opts = json::parse(job.optionsJson, nullptr, /*allow_exceptions=*/false);
        if (!opts.is_array()) {
            return makeErr("PERMANENT", "register options are not a RegistryOptions array");
        }
        int64_t rate = 0;
        json moduleOpts = json::object();
        for (const auto& o : opts) {
            if (!o.is_object() || !o.contains("key") || !o["key"].is_string()) {
                continue;
            }
            const std::string key = o["key"].get<std::string>();
            const std::string val = o.contains("value") && o["value"].is_string()
                ? o["value"].get<std::string>()
                : "";
            if (key == "rate_limit") {
                rate = strtoll(val.c_str(), nullptr, 10);
            } else {
                moduleOpts[key] = val;
            }
        }
        if (rate <= 0) {
            // The LIP lets rate_limit default registry-side; the module's
            // current wire requires it. Surface the gap instead of guessing.
            return makeErr("PERMANENT",
                "options carry no usable rate_limit (the module wire requires one)");
        }
        r = m_rln.tstr("register",
            json::array({job.registryId, job.rlnIdentifier, rate, moduleOpts.dump()}),
            kRegisterMs);
        break;
    }
    case Op::GetState:
        r = m_rln.tstr("get_membership_state",
            json::array({job.registryId, job.rlnIdentifier}), kReadMs);
        break;
    case Op::GetQuota:
        r = m_rln.result("get_epoch_quota",
            json::array({job.registryId, job.rlnIdentifier, ts}), kReadMs);
        break;
    case Op::Generate:
        r = m_rln.result("generate_proof",
            json::array({job.registryId, job.rlnIdentifier, job.signalHex, ts}), kReadMs);
        break;
    case Op::Verify:
        // Seam op name is delivery's `verify_proof`; the module method is
        // `validate_proof` (the 0.5.0 rename). THE mapping.
        r = m_rln.result("validate_proof",
            json::array({job.registryId, job.rlnIdentifier, job.signalHex, ts,
                         job.proofJson}),
            kReadMs);
        break;
    }

    if (r.ok) {
        return makeOk(r.value);
    }
    return makeModuleErr(r.errorObj);
}

bool RlnSeamBridge::subscribeMembershipEvent(
    std::function<void(const std::string&, const std::string&, const std::string&,
                       const std::string&, const std::string&)> onEvent)
{
    return m_rln.subscribeMembershipStateChanged(std::move(onEvent));
}
