# delivery — blocked on a configureRln deadlock

The scenario is complete and every step except one is verified against the
hosted testnet (`testnet-faucet-260908`, 2026-09-09): both nodes register a
real on-chain membership, come up on the layered Messaging-API config, peer
statically over `entry-node`, and a message sent by n1 arrives at n2 with its
payload intact. Running with `configureRln` stubbed out reaches the send and
the receive; the RLN-on path cannot get past node bring-up.

## The deadlock

`delivery_module.configureRln` never returns and wedges the module process
(logoscore has to SIGKILL it at shutdown). Two threads wait on each other:

- **the module's Qt dispatch thread** — `logos_module_dispatch` →
  `DeliveryModuleImpl::configureRln` → `RlnBridge::startBackend` →
  `RlnBridge::runLifecycle`, blocked on the lane's promise;
- **the bridge's fast lane** — `RlnBridge::laneLoop` → `serveOp` →
  `serveFast` → `LiblogosRlnModule::start` → `logos::LpClient::invoke` →
  `lp_client_create` → `QMetaObject::invokeMethodImpl` →
  `QSemaphore::acquire`.

`lp_client_create` marshals onto the module's Qt thread and blocks until it
runs. That thread is the one waiting for the lane, so neither proceeds and
`runLifecycle`'s 80 s budget never fires.

`configureRln` calling `startBackend` synchronously on the dispatch thread is
the shape at fault: the lane's first lp call needs the dispatch thread's event
loop. The module's own tests exercise the trampolines without a framework
context, so they cannot see it.

Owner: `logos-co/logos-delivery-module#100`. Note that
`liblogos_rln_module.start` itself is instant when called directly over the
CLI — it is only the in-module lp path that deadlocks.

## Second, smaller blocker

`logosctl call` has a fixed 20 s transport deadline and no CLI override
(`logos::Timeout`; only the catalog/transfer commands raise it), so even a
fixed `configureRln` that legitimately takes longer — it warms the registry
root window over the chain — cannot be driven from the CLI. The scenario
therefore fires `configureRln` and waits for the module's own verdict in the
daemon log instead of trusting the client's return.

## Running it

```sh
E2E_DEPLOYMENT=testnet-faucet-260908 ./run.sh delivery --target testnet
```
