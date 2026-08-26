#include "rln_seam_bridge.h"

#include <cstdio>

#include <nlohmann/json.hpp>

extern "C" {
#include <rlnconsumer_rln.h>
}

using nlohmann::json;

RlnSeamBridge::RlnSeamBridge() = default;

RlnSeamBridge::~RlnSeamBridge()
{
    if (m_installed) {
        // Clear the seam first: fails all in-flight rlnInvokes cleanly.
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
    cbs.start = &RlnSeamBridge::opTrampoline<Op::Start>;
    cbs.stop = &RlnSeamBridge::opTrampoline<Op::Stop>;
    cbs.register_membership = &RlnSeamBridge::opTrampoline<Op::Register>;
    cbs.get_membership_state = &RlnSeamBridge::opTrampoline<Op::GetState>;
    cbs.get_epoch_quota = &RlnSeamBridge::opTrampoline<Op::GetQuota>;
    cbs.generate_proof = &RlnSeamBridge::opTrampoline<Op::Generate>;
    cbs.verify_proof = &RlnSeamBridge::opTrampoline<Op::Verify>;
    rlnconsumer_rln_set_callbacks(&cbs, this);
    m_installed = true;
}

void RlnSeamBridge::enqueue(uint64_t reqId, Op op, const char* payload)
{
    // Runs on the Nim chronos thread — return immediately, never call the
    // module here.
    {
        std::lock_guard<std::mutex> lock(m_lock);
        m_queue.push_back(Job{reqId, op, payload ? payload : "{}"});
    }
    m_cv.notify_one();
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
            out = serveOp(job.op, job.payload);
        } catch (const std::exception& e) {
            out = json{{"ok", false},
                       {"error", {{"class", "permanent"}, {"kind", "bridge_exception"},
                                  {"message", e.what()}}}}
                      .dump();
        }
        // Late replies (Nim side timed out) return non-zero; nothing to do.
        rlnconsumer_rln_response(job.reqId, out.c_str());
    }
}

std::string RlnSeamBridge::serveOp(Op op, const std::string& payloadJson)
{
    json p = json::parse(payloadJson, nullptr, /*allow_exceptions=*/false);
    if (p.is_discarded()) {
        p = json::object();
    }
    auto str = [&p](const char* key) {
        return p.contains(key) && p[key].is_string() ? p[key].get<std::string>() : std::string();
    };

    // lp timeouts mirror the module's own internal legs (membership module
    // provider.rs: reads 70s, register submit 190s). The Nim seam's per-op
    // timeout is usually the binding constraint; a late completion here just
    // gets dropped by rlnconsumer_rln_response (rc 1).
    constexpr int kReadMs = 70'000;
    constexpr int kRegisterMs = 190'000;

    RlnModuleResult r;
    switch (op) {
    case Op::Start:
        r = m_rln.result("start", json::array({str("config_json")}), kReadMs);
        break;
    case Op::Stop:
        r = m_rln.result("stop", json::array(), kReadMs);
        break;
    case Op::Register: {
        // rate_limit stays a JSON integer — the module dispatch reads a
        // float (or string) as 0.
        int64_t rate = p.contains("rate_limit") && p["rate_limit"].is_number_integer()
            ? p["rate_limit"].get<int64_t>()
            : 0;
        r = m_rln.tstr("register",
            json::array({str("registry_id"), str("rln_identifier_hex"), rate,
                         str("options_json")}),
            kRegisterMs);
        break;
    }
    case Op::GetState:
        r = m_rln.tstr("get_membership_state",
            json::array({str("registry_id"), str("rln_identifier_hex")}), kReadMs);
        break;
    case Op::GetQuota:
        // timestamps cross the module wire as strings
        r = m_rln.result("get_epoch_quota",
            json::array({str("registry_id"), str("rln_identifier_hex"), str("timestamp")}),
            kReadMs);
        break;
    case Op::Generate:
        r = m_rln.result("generate_proof",
            json::array({str("registry_id"), str("rln_identifier_hex"), str("signal_hex"),
                         str("timestamp")}),
            kReadMs);
        break;
    case Op::Verify:
        // Seam op name is delivery's `verify_proof`; the module method is
        // `validate_proof` (the 0.5.0 rename). THE mapping.
        r = m_rln.result("validate_proof",
            json::array({str("registry_id"), str("rln_identifier_hex"), str("signal_hex"),
                         str("timestamp"), str("proof_json")}),
            kReadMs);
        break;
    }

    if (r.ok) {
        return json{{"ok", true}, {"value", r.value}}.dump();
    }
    return json{{"ok", false}, {"error", r.errorObj}}.dump();
}

bool RlnSeamBridge::subscribeMembershipEvent(
    std::function<void(const std::string&, const std::string&, const std::string&,
                       const std::string&, const std::string&)> onEvent)
{
    return m_rln.subscribeMembershipStateChanged(std::move(onEvent));
}
