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

} // namespace

bool RlnSeamBridge::isTstrOp(Op op)
{
    return op == Op::Register || op == Op::GetState;
}

std::string RlnSeamBridge::transportFail(Op op, const std::string& cls,
                                         const std::string& kind, const std::string& msg)
{
    const json errorObj{{"class", cls}, {"kind", kind}, {"message", msg}};
    if (isTstrOp(op)) {
        return json{{"error", errorObj}}.dump();
    }
    // result dialect: the envelope's error arm is a JSON-ENCODED object.
    return json{{"success", false}, {"error", errorObj.dump()}}.dump();
}

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
    cbs.validate_proof = &RlnSeamBridge::validateTrampoline;
    rlnconsumer_rln_set_callbacks(&cbs, this);
    m_installed = true;
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

void RlnSeamBridge::startTrampoline(uint64_t reqId, const char* configJson, void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Start;
    j.configJson = toStringOrEmpty(configJson);
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

void RlnSeamBridge::validateTrampoline(uint64_t reqId, const char* registryId,
                                     const char* rlnIdentifier, const char* signalHex,
                                     uint64_t timestamp, const char* proofJson,
                                     void* userData)
{
    Job j;
    j.reqId = reqId;
    j.op = Op::Validate;
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
            out = transportFail(job.op, "permanent", "bridge_exception",
                std::string("bridge exception: ") + e.what());
        }
        // Late replies (Nim side timed out) return non-zero; nothing to do.
        rlnconsumer_rln_response(job.reqId, out.c_str());
    }
}

std::string RlnSeamBridge::serveOp(const Job& job)
{
    // lp timeouts mirror the module's own internal legs (membership module
    // provider.rs: reads 70s, register submit 190s). The Nim seam's per-op
    // budget (delivery's 95s registry-read / 10s local) is usually the
    // binding constraint; a late completion here just gets dropped by
    // rlnconsumer_rln_response (rc 1).
    constexpr int kReadMs = 70'000;
    constexpr int kRegisterMs = 190'000;

    const std::string ts = std::to_string(job.timestamp); // module wants a STRING

    RlnModuleRaw r;
    switch (job.op) {
    case Op::Start:
        // The start config rides the seam now — pass it to the module
        // verbatim; the bridge owns no out-of-band start knowledge.
        r = m_rln.raw("start", json::array({job.configJson}), kReadMs);
        break;
    case Op::Stop:
        r = m_rln.raw("stop", json::array(), kReadMs);
        break;
    case Op::Register:
        // The seam's LIP RegistryOptions array IS the module wire (0.6) —
        // pass it through verbatim; the module lifts the common rate_limit
        // key (and applies its default when absent) itself.
        r = m_rln.raw("register_membership",
            json::array({job.registryId, job.rlnIdentifier, job.optionsJson}), kRegisterMs);
        break;
    case Op::GetState:
        r = m_rln.raw("get_membership_state",
            json::array({job.registryId, job.rlnIdentifier}), kReadMs);
        break;
    case Op::GetQuota:
        r = m_rln.raw("get_epoch_quota",
            json::array({job.registryId, job.rlnIdentifier, ts}), kReadMs);
        break;
    case Op::Generate:
        r = m_rln.raw("generate_proof",
            json::array({job.registryId, job.rlnIdentifier, job.signalHex, ts}), kReadMs);
        break;
    case Op::Validate:
        // One name end to end: seam op and module method are validate_proof.
        r = m_rln.raw("validate_proof",
            json::array({job.registryId, job.rlnIdentifier, job.signalHex, ts,
                         job.proofJson}),
            kReadMs);
        break;
    }

    if (!r.ok) {
        auto field = [&r](const char* k) {
            return r.errorObj.contains(k) && r.errorObj[k].is_string()
                ? r.errorObj[k].get<std::string>()
                : std::string();
        };
        return transportFail(job.op,
            field("class").empty() ? "transient" : field("class"),
            field("kind").empty() ? "transport" : field("kind"),
            field("message").empty() ? r.errorObj.dump() : field("message"));
    }
    return r.text; // the module's reply, verbatim
}

bool RlnSeamBridge::subscribeMembershipEvent(
    std::function<void(const std::string&, const std::string&, const std::string&,
                       const std::string&, const std::string&)> onEvent)
{
    return m_rln.subscribeMembershipStateChanged(std::move(onEvent));
}
