#pragma once

// The host side of the mirrored delivery RLN seam (rlnconsumer_rln.h): the 7
// typed op callbacks the Nim library invokes, served against the real
// liblogos_rln_module over the lp wire.
//
// Seam contract: op callbacks must return immediately (the Nim side awaits a
// ThreadSignalPtr), so every op is queued to one worker thread. The worker
// owns the RlnModuleClient — lp clients are owner-thread-bound, and a single
// worker gives every module call a consistent, live owner.
//
// Response convention — the reply envelope delivery-module docs/rln.md
// documents for every responder:
//   {"ok": <module reply>} | {"err": {"kind": <LIP kind>, "message": ...}}
// with kind one of NOT_READY | TRANSIENT | BUDGET_EXHAUSTED | PERMANENT.
// The tstr/result dialect split of the module wire is absorbed here, so the
// Nim side sees only the envelope. The seam op and the module method are
// both named `validate_proof` (one name end to end since the
// rln/integration-fixes rename).
//
// The seam's start op carries no scope, so the module's start config
// ({epoch_size_sec, registries}) is bridge-owned: the plugin hands it over
// at createConsumer (setStartScope) — the out-of-band knowledge any real
// responder needs. Register options arrive as the LIP RegistryOptions
// key/value array; the bridge maps them onto the module's
// register(rate_limit, options_object) wire.

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

    // The module start config the seam cannot carry. Called by the plugin's
    // createConsumer (any dispatch thread).
    void setStartScope(const std::string& registryId, const std::string& epochSizeSec);

    // Subscribe to liblogos_rln_module's membership_state_changed and forward
    // the 5-string payload. Rides the main-owned lp client; callable from any
    // dispatch thread. Returns true once subscribed.
    bool subscribeMembershipEvent(
        std::function<void(const std::string&, const std::string&, const std::string&,
                           const std::string&, const std::string&)> onEvent);

private:
    enum class Op { Start, Stop, Register, GetState, GetQuota, Generate, Validate };

    struct Job {
        uint64_t reqId = 0;
        Op op = Op::Start;
        // Typed seam args; each op fills what its callback carries.
        std::string registryId;
        std::string rlnIdentifier;
        std::string signalHex;
        std::string optionsJson; // LIP RegistryOptions key/value array
        std::string proofJson;
        uint64_t timestamp = 0;
    };

    void enqueue(Job job);
    void workerLoop();
    std::string serveOp(const Job& job);

    // One typed trampoline per callback (the shape delivery_module itself
    // uses): copy the borrowed strings, queue, return.
    static void startTrampoline(uint64_t reqId, void* userData);
    static void stopTrampoline(uint64_t reqId, void* userData);
    static void registerTrampoline(uint64_t reqId, const char* registryId,
                                   const char* rlnIdentifier, const char* optionsJson,
                                   void* userData);
    static void getStateTrampoline(uint64_t reqId, const char* registryId,
                                   const char* rlnIdentifier, void* userData);
    static void getQuotaTrampoline(uint64_t reqId, const char* registryId,
                                   const char* rlnIdentifier, uint64_t timestamp,
                                   void* userData);
    static void generateTrampoline(uint64_t reqId, const char* registryId,
                                   const char* rlnIdentifier, const char* signalHex,
                                   uint64_t timestamp, void* userData);
    static void validateTrampoline(uint64_t reqId, const char* registryId,
                                 const char* rlnIdentifier, const char* signalHex,
                                 uint64_t timestamp, const char* proofJson,
                                 void* userData);

    std::mutex m_lock;
    std::condition_variable m_cv;
    std::deque<Job> m_queue;
    bool m_stopping = false;
    bool m_installed = false;
    std::thread m_worker;

    // start scope (guarded by m_lock; set once at createConsumer)
    std::string m_startRegistryId;
    std::string m_startEpochSizeSec;

    RlnModuleClient m_rln; // lp client created in install() (main thread)
};
