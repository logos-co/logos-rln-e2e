#pragma once

// The host side of the mirrored delivery RLN seam (rlnconsumer_rln.h): the 7
// opaque-JSON op callbacks the Nim library invokes, served against the real
// liblogos_rln_module over the lp wire.
//
// Seam contract: op callbacks must return immediately (the Nim side awaits a
// ThreadSignalPtr), so every op is queued to one worker thread. The worker
// owns the RlnModuleClient — lp clients are owner-thread-bound, and a single
// worker gives every module call a consistent, live owner.
//
// Response convention (this pair owns the seam's payload schema):
//   {"ok":true,"value":<module reply>} |
//   {"ok":false,"error":{"class","kind","message"}}
// The tstr/result dialect split of the module wire is absorbed here, so the
// Nim side sees one dialect. The seam op `verify_proof` (delivery's name)
// maps to the module method `validate_proof`.

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "rln_module_client.h"

class RlnSeamBridge {
public:
    RlnSeamBridge();
    ~RlnSeamBridge();

    // Install the 7 callbacks into librlnconsumer (rlnconsumer_rln_set_callbacks),
    // create the lp client to the RLN module, and start the worker. Call once,
    // from onContextReady: that runs on the process MAIN thread before its Qt
    // loop starts pumping, making main the lp client's owner — the one thread
    // that pumps for the process lifetime, so async completions and event
    // deliveries always have a live delivery thread. (This module runs
    // concurrency:"multi": dispatches execute on glue worker threads, so a
    // blocking method never stalls main's pump — the single-concurrency
    // variant deadlocks exactly there.)
    void install();

    // Subscribe to liblogos_rln_module's membership_state_changed and forward
    // the 5-string payload. Rides the main-owned lp client; callable from any
    // dispatch thread. Returns true once subscribed.
    bool subscribeMembershipEvent(
        std::function<void(const std::string&, const std::string&, const std::string&,
                           const std::string&, const std::string&)> onEvent);

private:
    enum class Op { Start, Stop, Register, GetState, GetQuota, Generate, Verify };

    struct Job {
        uint64_t reqId;
        Op op;
        std::string payload;
    };

    void enqueue(uint64_t reqId, Op op, const char* payload);
    void workerLoop();
    std::string serveOp(Op op, const std::string& payloadJson);

    template <Op O>
    static void opTrampoline(uint64_t reqId, const char* payload, void* userData)
    {
        static_cast<RlnSeamBridge*>(userData)->enqueue(reqId, O, payload);
    }

    std::mutex m_lock;
    std::condition_variable m_cv;
    std::deque<Job> m_queue;
    bool m_stopping = false;
    bool m_installed = false;
    std::thread m_worker;

    RlnModuleClient m_rln; // lp client created in install() (main thread)
};
