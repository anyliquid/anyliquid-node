# Oracle Fetcher

## Overview

The Oracle Fetcher is a standalone process responsible for sourcing external price data from centralized exchanges and submitting signed price reports to the Node. It runs independently of both the API Server and the Node, communicating with the Node exclusively through signed `OracleSubmission` actions — the same mechanism any validator agent uses.

```
┌─────────────────────────────────────────────────────────────┐
│                     Oracle Fetcher Process                   │
│                                                              │
│   ┌────────────┐   ┌────────────┐   ┌────────────────────┐  │
│   │  Binance   │   │    OKX     │   │      Bybit         │  │
│   │  Source    │   │   Source   │   │      Source        │  │
│   └─────┬──────┘   └─────┬──────┘   └────────┬───────────┘  │
│         └────────────────┼───────────────────┘              │
│                          ▼                                   │
│                 ┌────────────────┐                           │
│                 │  Aggregator    │                           │
│                 │  · median      │                           │
│                 │  · staleness   │                           │
│                 │  · deviation   │                           │
│                 └───────┬────────┘                           │
│                         ▼                                    │
│                 ┌────────────────┐                           │
│                 │   Submitter    │                           │
│                 │  · sign w/     │                           │
│                 │    agent key   │                           │
│                 │  · IPC → Node  │                           │
│                 └────────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

The Node's oracle module treats these submissions as opaque signed actions — it validates the signature, records the price, and includes it in the next block's aggregation. The fetcher has no awareness of consensus internals.

## Why a Separate Process

- **No foreign I/O in the Node's main loop.** HTTP calls to CEX REST APIs have unpredictable latency and can fail. Blocking the deterministic execution pipeline on an external HTTP call would be catastrophic for block times.
- **Key isolation.** The agent signing key used for oracle submissions does not need to be co-located with the validator's consensus signing key. Running them in separate processes reduces the blast radius of a key compromise.
- **Independent restart.** The fetcher can crash and recover without affecting consensus. Price submissions will resume once it restarts; the Node simply treats missed rounds as absent submissions from that validator.
- **Deployability.** Validators running multiple sentry nodes don't need to run a fetcher per sentry — one fetcher per validator is sufficient. It submits via any connected Node IPC path.

---

## Module List

| Module | File | Responsibility |
|--------|------|----------------|
| Source: Binance | `modules/source_binance.md` | Fetch spot/perp mid prices from Binance |
| Source: OKX | `modules/source_okx.md` | Fetch spot/perp mid prices from OKX |
| Source: Bybit | `modules/source_bybit.md` | Fetch spot/perp mid prices from Bybit |
| Aggregator | `modules/aggregator.md` | Median, staleness check, deviation guard |
| Submitter | `modules/submitter.md` | Sign and submit OracleSubmission to Node |
| Config | `modules/config.md` | Source weights, asset mapping, intervals |

---

## Data Flow

```
Every N milliseconds (configurable, default 2000ms):

  1. Fetch prices in parallel from all configured sources
       Binance.fetch() ──┐
       OKX.fetch()    ──→ raw PriceSet[]   (concurrent io_uring HTTP)
       Bybit.fetch()  ──┘

  2. Aggregator receives raw sets
       · drop stale entries (age > max_age_ms)
       · compute per-asset median across sources
       · reject if fewer than min_sources responded
       · reject per-asset price if deviation from previous > max_deviation_pct

  3. Submitter builds OracleSubmission
       · attach nonce = now_ms
       · sign with agent key (ECDSA, EIP-712 compatible)

  4. Send signed action to Node via IPC
       · fire-and-forget (no ACK wait)
       · if IPC unavailable: buffer latest prices, retry on reconnect
```

---

## Process Architecture

The fetcher uses a single-threaded `io_uring` event loop, identical to the Node and API layer. All concurrent HTTP fetches are issued as async requests and harvested in the same loop iteration — no threads, no blocking.

```zig
pub fn main() !void {
    var cfg     = try Config.loadFromFile("config.toml");
    var sources = try Sources.init(cfg, alloc);
    var agg     = Aggregator.init(cfg.assets, alloc);
    var sub     = try Submitter.init(cfg.agent_key, cfg.node_ipc_path, alloc);
    var ring    = try io_uring.init(256, 0);

    var next_fetch_ms = std.time.milliTimestamp();

    while (true) {
        const now = std.time.milliTimestamp();

        if (now >= next_fetch_ms) {
            // Issue all HTTP fetches as async io_uring requests
            try sources.fetchAll(&ring);
            next_fetch_ms = now + cfg.fetch_interval_ms;
        }

        // Harvest completed requests
        const cqes = try ring.copyReadyCompletions(scratch_buf);
        for (cqes) |cqe| {
            const result = sources.handleCompletion(cqe) orelse continue;

            if (agg.ingest(result)) |prices| {
                // Aggregation produced a submittable price set
                try sub.submit(prices);
            }
        }
    }
}
```

---

## Configuration (`config.toml`)

```toml
fetch_interval_ms = 2000     # how often to fetch from all sources
max_age_ms        = 4000     # reject source prices older than this
min_sources       = 2        # minimum sources required to produce a submission
max_deviation_pct = 2.0      # per-asset: reject if > 2% from last submitted price
submit_timeout_ms = 1000     # IPC write timeout

agent_key         = "0x..."  # hex-encoded private key (or path to keyfile)
node_ipc_path     = "/var/run/hyperzig/node.sock"

[[assets]]
name       = "BTC"
asset_id   = 0
# per-source symbol mapping
binance_symbol = "BTCUSDT"
okx_symbol     = "BTC-USDT"
bybit_symbol   = "BTCUSDT"

[[assets]]
name       = "ETH"
asset_id   = 1
binance_symbol = "ETHUSDT"
okx_symbol     = "ETH-USDT"
bybit_symbol   = "ETHUSDT"

[[sources]]
name    = "binance"
weight  = 1
enabled = true
base_url = "https://api.binance.com"

[[sources]]
name    = "okx"
weight  = 1
enabled = true
base_url = "https://www.okx.com"

[[sources]]
name    = "bybit"
weight  = 1
enabled = true
base_url = "https://api.bybit.com"
```

---

## Metrics

The fetcher exposes a minimal HTTP metrics endpoint (`/metrics`) in Prometheus format for alerting:

| Metric | Type | Description |
|--------|------|-------------|
| `oracle_fetch_ok_total` | counter | Successful fetches per source |
| `oracle_fetch_err_total` | counter | Failed fetches per source |
| `oracle_source_latency_ms` | histogram | HTTP round-trip latency per source |
| `oracle_submission_total` | counter | Submissions sent to Node |
| `oracle_submission_skipped_total` | counter | Rounds skipped (min_sources not met, or deviation exceeded) |
| `oracle_price_age_ms` | gauge | Age of last successfully submitted price per asset |
| `oracle_node_ipc_connected` | gauge | 1 if IPC connection to Node is alive |