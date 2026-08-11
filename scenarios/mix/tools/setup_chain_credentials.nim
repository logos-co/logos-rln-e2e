{.push raises: [].}

## Credential + tree provisioning for the mix scenario, derived from the mix
## stack's own simulations/mixnet/setup_credentials.nim — same plugin APIs,
## same keystore/tree formats, same hardcoded password protocol.nim expects —
## with two additions that bridge the membership set to the chain:
##
##   1. members.json — the registration manifest, in tree-insertion order:
##      [{"peer_id","id_commitment","rate_limit"}, …]. The harness registers
##      exactly this list, in this order, on-chain via
##      liblogos_lez_rln_module.register_member.
##   2. TREE_ROOT=<hex> on stdout — the plugin tree's root. Both trees are
##      depth-20 zerokit trees whose leaves are Poseidon(idCommitment,
##      rate_limit), so after on-chain registration this root must appear in
##      the registry's get_valid_roots. That equality is the scenario's
##      defining assertion.
##
## Node set: the stack's own 7 fixture identities (5 mix nodes + 2 chat
## clients) — peer ids derived from the nodekeys in the sim configs; reusing
## them keeps keystore filenames (rln_keystore_<peerId>.json) aligned with
## the nodekeys the harness writes into node configs.
##
## Compile like the stack's build_setup.sh (from the checkout root, deps
## staged by `make deps`, librln linked): the harness does this in
## scenarios/mix/lib/chain_register.sh.

import std/[os, strformat, options, json], chronicles, chronos, results

import
  mix_rln_spam_protection/credentials,
  mix_rln_spam_protection/group_manager,
  mix_rln_spam_protection/rln_interface,
  mix_rln_spam_protection/types

const
  KeystorePassword = "mix-rln-password" # Must match protocol.nim
  DefaultUserMessageLimit = 100'u64 # R=100; also the registry's min_rate_limit

  # Peer IDs derived from the nodekeys in the harness node configs
  # (scenarios/mix/lib/nodes.sh writes the same nodekeys).
  NodeConfigs = [
    ("16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o", DefaultUserMessageLimit),
      # node0 (bootstrap/service)
    ("16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF", DefaultUserMessageLimit),
      # node1
    ("16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA", DefaultUserMessageLimit),
      # node2
    ("16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f", DefaultUserMessageLimit),
      # node3
    ("16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu", DefaultUserMessageLimit),
      # node4
    ("16Uiu2HAm1QxSjNvNbsT2xtLjRGAsBLVztsJiTHr9a3EK96717hpj", DefaultUserMessageLimit),
      # chat client A
    ("16Uiu2HAmC9h26U1C83FJ5xpE32ghqya8CaZHX1Y7qpfHNnRABscN", DefaultUserMessageLimit),
      # chat client B
  ]

proc setupCredentialsAndTree() {.async.} =
  echo "=== RLN chain-bridged credentials setup ==="
  echo "Generating credentials for ", NodeConfigs.len, " nodes...\n"

  var allCredentials:
    seq[tuple[peerId: string, cred: IdentityCredential, rateLimit: uint64]]
  for (peerId, rateLimit) in NodeConfigs:
    let cred = generateCredentials().valueOr:
      echo "Failed to generate credentials for ", peerId, ": ", error
      quit(1)
    allCredentials.add((peerId: peerId, cred: cred, rateLimit: rateLimit))
    echo "Generated credentials for ", peerId
    echo "  idCommitment: ", cred.idCommitment.toHex()

  let rlnInstance = newRLNInstance().valueOr:
    echo "Failed to create RLN instance: ", error
    quit(1)
  let groupManager = newOffchainGroupManager(rlnInstance, "/mix/rln/membership/v1")
  let initRes = await groupManager.init()
  if initRes.isErr:
    echo "Failed to initialize group manager: ", initRes.error
    quit(1)

  echo "\nRegistering all credentials in the Merkle tree..."
  for i, entry in allCredentials:
    let index = (
      await groupManager.registerWithLimit(entry.cred.idCommitment, entry.rateLimit)
    ).valueOr:
      echo "Failed to register credential for ", entry.peerId, ": ", error
      quit(1)
    echo "  Registered ",
      entry.peerId, " at index ", index, " (limit: ", entry.rateLimit, ")"

  echo "\nSaving tree to rln_tree.db..."
  let saveRes = groupManager.saveTreeToFile("rln_tree.db")
  if saveRes.isErr:
    echo "Failed to save tree: ", saveRes.error
    quit(1)

  echo "Saving keystores..."
  for i, entry in allCredentials:
    let keystorePath = &"rln_keystore_{entry.peerId}.json"
    let saveResult = saveKeystore(
      entry.cred,
      KeystorePassword,
      keystorePath,
      some(MembershipIndex(i)),
      some(entry.rateLimit),
    )
    if saveResult.isErr:
      echo "Failed to save keystore for ", entry.peerId, ": ", saveResult.error
      quit(1)
    echo "  Saved: ", keystorePath

  # The chain-bridge additions: the registration manifest + the tree root.
  try:
    var members = newJArray()
    for entry in allCredentials:
      members.add(
        %*{
          "peer_id": entry.peerId,
          "id_commitment": entry.cred.idCommitment.toHex(),
          "rate_limit": entry.rateLimit,
        }
      )
    writeFile("members.json", $members)
  except CatchableError as e:
    echo "Failed to write members.json: ", e.msg
    quit(1)

  let root = rlnInstance.getMerkleRoot().valueOr:
    echo "Failed to read tree root: ", error
    quit(1)

  echo "\n=== Setup complete ==="
  echo "  Members:  ", NodeConfigs.len, " (members.json, insertion order)"
  echo "  Tree:     rln_tree.db"
  echo "TREE_ROOT=", root.toHex()

when isMainModule:
  waitFor setupCredentialsAndTree()
