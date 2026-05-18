# dns-ultra — DNS Resolver Benchmark for dnscrypt-proxy

[![Release](https://img.shields.io/github/v/release/Ozy-666/dns-ultra?style=flat-square&color=blue)](https://github.com/Ozy-666/dns-ultra/releases/latest)
[![License](https://img.shields.io/github/license/Ozy-666/dns-ultra?style=flat-square&color=green)](LICENSE)
[![Made with Bash](https://img.shields.io/badge/Bash-100%25-1f425f?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![dnscrypt-proxy](https://img.shields.io/badge/dnscrypt--proxy-2.1.15+-orange?style=flat-square)](https://github.com/DNSCrypt/dnscrypt-proxy)

**Find the fastest, most reliable upstream DNS resolvers for your dnscrypt-proxy setup — automatically.**

`dns-ultra` is a Bash script that tests hundreds of public DNS resolvers and tells you exactly which ones are worth using as upstreams for dnscrypt-proxy. It runs real queries, measures what actually matters in day-to-day use, and outputs a ready-to-paste config block. No guessing, no manual testing.

<p align="center">
  <img src="images/screenshot.png" width="880" alt="dns-ultra terminal output showing DNS resolver benchmark results">
</p>

---

## What does it do?

In short: it fires up dnscrypt-proxy for each candidate resolver, runs a structured set of DNS queries, measures latency and reliability, scores everything, and prints a ranked table with a recommended config at the end.

It tests four things per resolver:

- **Fast-path** — How fast does it answer for popular domains like google.com, github.com, cloudflare.com? This is what your users actually experience every day.
- **Recursion** — How does it handle a brand-new domain it has never seen before? Measures the worst-case lookup time.
- **Burst** — Can it handle a rapid series of queries without dropping any? Both sequential and parallel.
- **Cold-start** — How long does it take from a fresh connection to the first working answer?

The final score is weighted heavily toward the fast-path and consistency, because that is what matters most when you have a local caching layer (like Unbound) in front of dnscrypt-proxy.

---

## Why this exists

Most DNS benchmark tools make the same mistake: they mix cached and uncached lookups into one average, then rank by that average. This breaks results badly. A few slow uncached lookups (like resolving a random subdomain of kernel.org for the first time) can make an excellent anycast resolver like Cloudflare or Quad9 look worse than a sketchy VPS resolver that got lucky.

`dns-ultra` was specifically built to fix this. It was created after watching Quad9 consistently lose rankings in other tools despite years of proven real-world reliability. The root cause was always bad methodology — not bad performance.

**What makes this different:**

- Separates cached fast-path queries from uncached recursive lookups — they are scored differently
- Gives recursion only 25% weight in the final score, because your local cache (Unbound, AdGuardHome) absorbs most misses anyway
- Uses jitter (latency consistency) as a primary scoring signal — a resolver that is always 8ms beats one that alternates between 3ms and 40ms
- Applies ethical query pacing (15ms for DoH, 50–150ms random for DNSCrypt) so the benchmark doesn't accidentally trigger rate limits and produce false failures
- Automatically detects whether a server uses DoH (DNS over HTTPS) or DNSCrypt and adjusts test behavior accordingly
- Pins known-good resolvers (Cloudflare, Google) so they always appear in results as a baseline — even if their RTT didn't rank top-N that day
- Permanently excludes Quad9 DoH servers (see below) so they never contaminate your config

---

## Target stack

```
Your device → AdGuardHome → Unbound (cache) → dnscrypt-proxy → upstream resolver
```

If your setup includes a caching layer before dnscrypt-proxy, the fast-path score is what matters most — Unbound handles most misses, so the upstream only sees cache misses occasionally.

If you run dnscrypt-proxy directly without a caching layer above it, set `DNSCRYPT_CACHE=true` when running the script. The scores still apply, but recursion latency becomes more important to you.

---

## Quick Start

### Requirements

- **Linux or macOS** with Bash 4+
- **`dnscrypt-proxy`** v2.1.0 or newer (auto-detected — see below)
- Standard tools: `dig`, `awk`, `sed`, `grep`, `sort`, `xargs`, `openssl`, `jq`

On Ubuntu/Debian, install the tools with:
```bash
sudo apt install dnsutils openssl jq
```

### Install and run

```bash
# Clone the repo
git clone https://github.com/Ozy-666/dns-ultra.git
cd dns-ultra

# Make it executable
chmod +x dns-ultra.sh

# Run the full benchmark (~12–15 minutes)
./dns-ultra.sh

# Or run a quick test to get a feel for it (~3–5 minutes, fewer candidates)
./dns-ultra.sh --quick
```

### Where is dnscrypt-proxy?

The script finds it automatically. It checks your system `$PATH` first, then scans common install locations like `/opt/dnscrypt-proxy/`, `/usr/local/bin/`, and portable archive folders. If it can't find it, set the path manually:

```bash
PROXY_BIN=/your/path/to/dnscrypt-proxy ./dns-ultra.sh
```

---

## What you get at the end

After the benchmark finishes, you get:

1. **A ranked table** of all tested resolvers, sorted from best to worst score
2. **A fast-path-only ranking** showing the top 10 for pure lookup speed
3. **A tail offender breakdown** showing which specific domains caused high P95 latency
4. **A ready-to-paste dnscrypt-proxy config block** with the top reliable servers
5. **Two JSON files** with full metrics for every server:
   - `dns-benchmark-results-v8.json` — all scores and statistics per server
   - `dns-benchmark-domain-tails-v8.json` — per-domain breakdown

The output looks like this in the terminal (see screenshot above). Servers marked `ok` are solid. `watch` means minor packet loss worth monitoring. `weak` means real reliability issues — these are excluded from the recommended config automatically.

---

## Configuration

All settings are environment variables. The defaults work well for most setups. The `--quick` flag is a convenient shortcut that reduces candidate count and rounds for faster iteration.

| Variable | Default | `--quick` | What it does |
|---|---|---|---|
| `PROXY_BIN` | auto-detect | — | Path to your dnscrypt-proxy binary |
| `TOP_PHASE2` | `24` | `6` | How many top-RTT servers to deep-profile |
| `FASTPATH_ROUNDS` | `5` | `3` | Query repetitions per fast-path domain |
| `RECURSION_ROUNDS` | `6` | `2` | Query repetitions per recursion target |
| `SEQ_BURST_QUERIES` | `35` | `10` | Number of sequential burst queries |
| `PAR_BURST_QUERIES` | `30` | `10` | Number of parallel burst queries |
| `COLDSTART_SAMPLES` | `3` | `1` | Fresh-connection latency measurements |
| `TIMEOUT` | `120` | `30` | Max seconds for the discovery phase |
| `LISTEN_IP` | `127.0.0.1` | — | Loopback IP for spawned proxy instances |
| `BASE_PORT` | `55000` | — | Starting port number for proxy instances |
| `DNSCRYPT_CACHE` | `false` | — | Enable proxy cache (set `true` only if no Unbound above) |

---

## How the score works

Lower score = better resolver. Here is the formula:

```
fast-path  = (median × 0.30) + (P95 × 0.25) + (jitter × 0.30) + (loss%² × 3)
recursion  = ((median × 0.10) + (P95 × 0.12) + (loss% × 10)) × 0.25
burst      = (sequential P95 × 0.030) + (parallel P95 × 0.010)
cold-start = min(cold_ms, 100) × 0.01

total score = fast-path + recursion + burst + cold-start
```

**The key ideas behind the weights:**

- **Jitter matters as much as median.** A resolver that answers in 8ms every time beats one that alternates between 4ms and 40ms. Jitter and median both carry 0.30 weight on the fast-path.
- **Packet loss is punished hard.** Loss is squared, so 1% loss costs ~3 points but 5% loss costs ~75 points. A single noisy packet is forgiven; persistent drops are not.
- **Recursion is a tiebreaker, not the main event.** The 0.25 multiplier means even a very slow uncached lookup barely moves the score. Your local cache handles those anyway.
- **Cold-start is capped at 100ms.** DNSCrypt servers fetch a certificate on first connection, which can spike to 999ms on a bad day. We cap this so one outlier doesn't ruin the ranking.

---

## DoH vs DNSCrypt — what the benchmark discovered

One of the most interesting findings from real-world testing is how differently the same resolver behaves depending on whether you use DoH (DNS over HTTPS) or DNSCrypt.

**Here is what the numbers showed from a VPS node in Finland:**

| Server | Protocol | Packet loss | Score |
|---|---|---|---|
| `quad9-dnscrypt-ip4-nofilter-pri` | DNSCrypt | **0.00%** | 14.20 |
| `quad9-doh-ip4-port443-nofilter-pri` | DoH | **4–6%** | 91.63 |
| `cloudflare` | DoH | **0.00%** | 6.88 |

Same Quad9 infrastructure, same VPS, same network. Only the transport protocol changed.

**Why does Quad9 DoH drop packets but Cloudflare DoH doesn't?**

DoH sends your DNS queries inside a persistent HTTPS connection. Quad9's servers limit how many queries can travel through a single connection before they cut you off. Cloudflare's servers are built for enormous scale and don't enforce that limit in the same way.

DNSCrypt sends each query as a separate encrypted UDP packet. There is no persistent connection to rate-limit. Every packet is independent, so Quad9's rate-limiting doesn't apply at all.

**What this means for you:** Using Quad9 DNSCrypt gives you the exact same privacy, the exact same DNSSEC security checks, and 0% packet loss — while Quad9 DoH from a server or VPS environment will silently drop 1 in 20 queries.

### Why Quad9 DoH is permanently excluded

The script blocks all `quad9-doh-*` server names from every test run. This means they can never appear in the discovery ranking and can never end up in your recommended config, even if they happen to show a fast RTT on the day you run the benchmark.

This is intentional. A server that drops 4–6% of queries under normal load is not a safe upstream for a production resolver chain. The DNSCrypt variant is strictly better in every measurable way.

---

## A note on DNSSEC-strict resolvers

Quad9, and a few others, validate DNSSEC on every query. This adds a small amount of work when resolving domains that don't have clean DNSSEC records, which shows up as slightly higher P95 on the recursion test.

This is not a bug or a sign of a bad resolver — it is a security feature doing its job. The scoring accounts for this with the 0.25 recursion multiplier, so DNSSEC-strict resolvers are not unfairly penalized.

---

## Recommended config format

At the end of every run, the script prints a block you can paste directly into your `dnscrypt-proxy.toml`:

```toml
server_names = [
    'cloudflare',
    'quad9-dnscrypt-ip4-nofilter-pri',
    'cs-swe',
    'cs-norway',
    'dnscry.pt-stockholm-ipv4',
]

lb_strategy = 'wp2'
lb_estimator = true
cache = false
```

`lb_strategy = 'wp2'` (weighted power-of-two) is the recommended setting for dnscrypt-proxy 2.1.5+. It picks two resolvers from your list at random and routes to whichever is faster at that moment. This keeps latency low without hammering a single server.

---

## Methodology limitations (honest)

- **One run = one data point.** Network conditions vary. Run the benchmark a few times at different hours before committing to a config.
- **Results are location-specific.** A resolver that is 5ms from your VPS might be 200ms from your actual users, and vice versa.
- **DoH servers get sequential burst testing.** The benchmark forces DoH servers through single-connection sequential burst testing (instead of parallel) to avoid triggering connection-level rate limits that would produce artificial failures. This means the DoH burst score reflects realistic sustained usage, not peak throughput.
- **Cold-start is an approximation.** We measure time from when dnscrypt-proxy reports it is ready to when the first query succeeds. Some resolvers do extra internal warmup not visible in logs.
- **The test is loopback-only.** The benchmark measures dnscrypt-proxy → upstream directly. It does not simulate AdGuardHome or Unbound sitting in front. The results represent the *quality of the upstream feed*, not end-to-end user latency.

---

## Contributing

Issues and pull requests are welcome. Most useful:

- New pinned resolvers worth always testing
- Geo-detection pattern improvements (the current regex is heuristic)
- Better Phase 1 discovery convergence detection
- macOS / BSD compatibility fixes

---

## 🤖 Development Process

This project follows a human-driven architecture approach with AI-assisted implementation. I do not write native code; I engineer the systems, the logic, and the validation methodology.

The production syntax, scoring weights, and edge-case handling were refined through iterative collaboration with multiple AI models:

- **Anthropic Claude (Opus 4.7 / Sonnet 4.6)** — primary architect for methodology fixes, code review, and statistical reasoning
- **Google Gemini** — secondary review and refactoring assistance
- **OpenAI ChatGPT / Codex** — early prototyping and bash idiom checks

The AI models acted as high-level tools to translate years of operational DNS resolver experience into clean, conformant Bash. All design decisions, methodology choices, and the v7 → v8 honesty correction were human-led.

If you find a bug, the responsibility is mine. If you find a clean idiom, credit the swarm.

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [DNSCrypt/dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) for the underlying tool and the public resolver list
- Authoritative DNS operators (Cloudflare, Google, Amazon, Microsoft, Wikimedia) who serve our recursion probes without complaint
