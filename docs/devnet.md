# Devnet: funding a payer and running against it

`--target devnet` runs the scenarios against a hosted LEZ zone (v0.2.5-rc3)
whose RLN programs are already provisioned. Nobody on it has genesis powers, so
native balance arrives the only way it can: a bedrock faucet drip, bridged
into the zone by a channel deposit from a node you run.

| | |
|---|---|
| Zone sequencer RPC | `http://209.38.241.182:3140/` |
| Zone indexer RPC | `http://209.38.241.182:8879/` |
| Zone explorer | `http://209.38.241.182:8188/` |
| Zone channel | `0202…02` (32 × `0x02`) |
| Bedrock | Logos blockchain devnet, node `0.3.0-rc.5` |
| Faucet | `https://devnet.blockchain.logos.co/web/faucet/` |

## 1. A payer the zone can credit

Mint one offline into a wallet kept outside the repo — it will hold real
devnet funds:

```sh
W=~/.local/share/logos-rln-e2e/devnet/payer-wallet   # any path outside the repo
mkdir -p $W
cat > $W/wallet_config.json <<'EOF'
{"sequencers":[{"sequencer_addr":"http://209.38.241.182:3140/"}],
 "seq_poll_timeout":"30s","seq_tx_poll_max_blocks":15,"seq_poll_max_retries":10,
 "seq_block_poll_max_amount":100,
 "multi_sequencer_client_config":{"distribution_limit":1,"calibration_limit":3}}
EOF
HOME=$W LEE_WALLET_HOME_DIR=$W ../logos-lez-rln/lez-rln/target/release/mint_payer
```

It prints the payer's base58 account id.

## 2. A bedrock node and a faucet drip

The faucet pays a bedrock note, not a zone account, and a deposit is signed by
the node's own wallet — so run a node:

```sh
./logos-blockchain-node init-config -o user_config.yaml \
    --http-host 127.0.0.1:8080 --state-path ./state --net-port 3000 \
    -p <the devnet peers from the 0.3.0-rc.5 release notes>
./logos-blockchain-node user_config.yaml --log-backend file --log-dir ./logs &
```

Take a key from `wallet.known_keys` in `user_config.yaml`, then:

```sh
curl -X POST https://devnet.blockchain.logos.co/web/faucet-backend/<key>   # 202 queued; 1e12, 5 min cooldown
curl http://127.0.0.1:8080/wallet/<key>/balance                            # .notes: {note_id: value}
```

## 3. Deposit into the zone

A deposit spends whole notes, so first make one of the exact amount:

```sh
curl -X POST -H 'Content-Type: application/json' \
  http://127.0.0.1:8080/wallet/transactions/transfer-funds \
  -d '{"tip":null,"change_public_key":"<key>","funding_public_keys":["<key>"],
       "recipient_public_key":"<key>","amount":<amount>}'
```

`metadata` is `borsh(DepositMetadata { recipient_id })` — the payer's 32-byte
account id, raw, sent as a JSON byte array:

```sh
python3 -c 'import json,sys; A="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
n=0
for c in sys.argv[1]: n=n*58+A.index(c)
print(json.dumps(list(n.to_bytes(32,"big"))))' <payer base58>

curl -X POST -H 'Content-Type: application/json' http://127.0.0.1:8080/channel/deposit \
  -d '{"tip":null,
       "deposit":{"channel_id":"0202020202020202020202020202020202020202020202020202020202020202",
                  "inputs":["<note_id>"],"metadata":[<32 bytes>]},
       "change_public_key":"<key>","funding_public_keys":["<key>"],"max_tx_fee":100000}'
```

The zone credits the payer only once the deposit is final on bedrock (k = 120
blocks, about an hour) and only while the zone sequencer is inscribing — if the
channel's last `ChannelInscribe` is old, nothing will land until it resumes.
Watch it:

```sh
curl -X POST -H 'Content-Type: application/json' http://209.38.241.182:3140/ \
  -d '{"jsonrpc":"2.0","id":1,"method":"getAccount","params":["<payer base58>"]}'
```

## 4. Provision and run

With the payer funded, provision a tree once (never re-run on the same tree):

```sh
../logos-lez-rln/tools/deployments/provision.sh --name devnet-z2 \
    --sequencer http://209.38.241.182:3140/ --payer <payer> \
    --adopt-wallet $W/storage.json --outdir <scratch>
```

Commit `deployment.json` to `deployments/devnet-z2/`, keep `storage.json` out
of the repo, and run:

```sh
E2E_PAYER_WALLET=<scratch>/devnet-z2/storage.json ./run.sh register --target devnet
```

The target defaults `E2E_FUND_AMOUNT` to 1e9 per node; a registration's fee
reserve is ~6.5e8, so a 1e12 drip covers several hundred node-runs.
