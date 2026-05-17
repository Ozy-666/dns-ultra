# dns-ultra
[![Release](https://img.shields.io/github/v/release/Ozy-666/dns-ultra?style=flat-square&color=blue)](https://github.com/Ozy-666/dns-ultra/releases/latest)
[![License](https://img.shields.io/github/license/Ozy-666/dns-ultra?style=flat-square&color=green)](LICENSE)
[![Made with Bash](https://img.shields.io/badge/Bash-100%25-1f425f?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![dnscrypt-proxy](https://img.shields.io/badge/dnscrypt--proxy-2.1.15+-orange?style=flat-square)](https://github.com/DNSCrypt/dnscrypt-proxy)

**A methodology-honest benchmark for picking dnscrypt-proxy upstream resolvers.**

`dns-ultra` measures DNS resolvers the way your real stack uses them. It separates **fast-path latency** (steady-state cached lookups, which is what your users actually experience) from **recursion-tail latency** (uncached authoritative walks, which a local cache layer absorbs anyway). It does not punish good anycast resolvers like Cloudflare or Quad9 because of one packet of noise.

## Why this exists

Most DNS benchmarks rank resolvers using a single mixed score: a few quick queries, an authoritative walk or two, average everything. This produces broken results — a couple of uncached `random.kernel.org` probes can dominate the median, and `loss × 18` makes one dropped packet outweigh several milliseconds of real latency.

`dns-ultra` was built after watching Quad9 lose rankings to faster-looking servers despite years of real-world reliability. The cause was always the same: noisy methodology amplified by aggressive loss penalties and unrealistic test patterns.

This version:

- Separates **fast-path** (real cached domains) from **recursion** (random subdomains against large operators only)
- Uses **ethical pacing** (50-150 ms between queries) so we don't trip rate limits on strict resolvers like Quad9
- Heavily downweights recursion in the final score because Unbound caches the result anyway
- Uses a **jitter-dominant score** because consistency matters more than peak speed for a caching upstream
- Caps cold-start penalties at 100 ms so DNSCrypt cert-fetch outliers don't dominate
- Probes random subdomains **only against large CDN operators** (Cloudflare, Google, Microsoft, Amazon, Wikipedia) — never against small auth servers like iana.org or kernel.org

## Target stack

```
client → AdGuardHome → Unbound (cache) → dnscrypt-proxy → upstream
```

If your stack already has a caching layer, you don't need a fast recursion tail — you need a consistent, low-loss, low-jitter upstream for cache misses. That's what this benchmark optimizes for.

If you have **no upstream cache** (e.g., dnscrypt-proxy is your only resolver), set `DNSCRYPT_CACHE=true` and `cache = true` in the recommended config. The score weights still apply, but you should give more weight to recursion when interpreting results.

## Quick start

```bash
# Standard 12-15 minute benchmark
./dns-ultra.sh

# Quick 3-minute scan for iterating
./dns-ultra.sh --quick

# Show only top 5 in the report
./dns-ultra.sh --top 5
```

## Requirements

- Bash 4+
- `dig` (bind-utils / dnsutils)
- `awk`, `sed`, `grep`, `sort`, `xargs` (POSIX standard)
- `openssl` (for random query labels)
- `jq` (for JSON output)
- `dnscrypt-proxy` 2.1.0+ — auto-detected from common paths or set `PROXY_BIN`

## Configuration

All knobs are environment variables. Defaults are sane for a 12-15 minute run on a 4-core VPS.

| Variable | Default | Purpose |
|---|---|---|
| `PROXY_BIN` | auto | Path to `dnscrypt-proxy` binary |
| `LISTEN_IP` | `127.0.0.1` | Loopback address for spawned proxies |
| `BASE_PORT` | `55000` | Starting port for proxy instances |
| `TOP_PHASE2` | `24` | Candidates to deep-profile after RTT discovery |
| `TIMEOUT` | `120` | Max seconds for Phase 1 discovery |
| `RTT_MAX_PHASE1` | `800` | Discard candidates with discovery RTT > this (ms) |
| `FASTPATH_ROUNDS` | `5` | Repetitions per fast-path domain |
| `RECURSION_ROUNDS` | `6` | Repetitions per recursion target |
| `SEQ_BURST_QUERIES` | `35` | Sequential burst sample size |
| `PAR_BURST_QUERIES` | `30` | Parallel burst sample size |
| `PAR_BURST_JOBS` | `3` | Parallel workers for burst test |
| `COLDSTART_SAMPLES` | `3` | Cold-start measurements per server |
| `DNSCRYPT_CACHE` | `false` | Enable dnscrypt-proxy's own cache (set true ONLY if no Unbound above) |

## What gets measured

### Fast-path (the king)
Fifteen popular real domains (Google, Cloudflare, GitHub, regional sites). Each tested 5 times after warmup. These should hit the upstream resolver's cache. This is the workload Unbound forwards on a cache miss.

### Recursion (the tail-latency canary)
Random subdomains against five large CDN operators (Cloudflare, Google, Amazon, Microsoft, Wikipedia). Defeats positive caching on purpose to measure how the resolver walks authoritative chains. Heavily downweighted because Unbound caches the result.

### Burst (concurrency tolerance)
- Sequential burst: 35 paced random queries back-to-back
- Parallel: 30 random queries with up to 3 concurrent workers

### Cold-start
Process startup → first successful query. Captures DNSCrypt cert-fetch overhead. Capped at 100 ms so failures don't dominate the score.

## Score formula

```
fastpath  = (f_median × 0.30) + (f_p95 × 0.25) + (f_jitter × 0.30) + (f_loss² × 3)
recursion = ((r_median × 0.10) + (r_p95 × 0.12) + (r_loss × 10)) × 0.25
burst     = (seq_p95 × 0.030) + (par_p95 × 0.010)
coldstart = min(cold_ms, 100) × 0.01

score     = fastpath + recursion + burst + coldstart
```

**Lower score is better.** Some intuitions:

- **Jitter has the same weight as median.** A consistent 8 ms upstream beats a flaky one that sometimes hits 4 ms and sometimes 40 ms.
- **Loss is squared.** A single dropped packet (0.8 %) costs ≈ 2 points. Sustained 5 % loss costs 75 points. This forgives noise but punishes real problems.
- **Recursion is multiplied by 0.25.** Unbound caches the result, so we treat tail-latency as a tiebreaker, not a primary signal.
- **Cold-start is capped and lightly weighted** — it matters once per restart.

## A note on DNSSEC-strict resolvers

Quad9 and other DNSSEC-validating resolvers show naturally higher P95 on the recursion profile because they perform NSEC validation on NXDOMAIN responses. This is a security feature, not a defect. The scoring is calibrated so this does not unfairly penalize them — that's the whole point of the 0.25 recursion multiplier.

If you see Quad9-DoH flagged as `weak` due to packet loss, that's separate — Quad9-DoH has stricter rate limiting than Quad9-DNSCrypt. The recommended-config block correctly prefers Quad9-DNSCrypt for this reason.

## Output files

| File | Contents |
|---|---|
| `dns-ultra-report.md` | Human-readable markdown report for issues/PRs |
| `dns-ultra-results.json` | All metrics per server, sorted by score |
| `dns-ultra-domain-tails.json` | Per-domain breakdown showing which names hurt P95 |

## Example output

```
SERVER                               PROTO    GEO        MED     P95     MAX     JIT     LOSS%   TRIMAVG
quad9-dnscrypt-ip4-nofilter-pri      DNSCrypt Anycast    6ms     7ms     NA      0.66    0.00    6.32   
nextdns-ultralow                     DoH      Anycast    7ms     8ms     NA      1.13    0.00    6.85   
cloudflare                           DoH      Anycast    4ms     14ms    NA      5.15    0.00    4.07   
cs-swe                               DNSCrypt swe        7ms     18ms    NA      6.36    0.00    7.25   
dnscry.pt-stockholm-ipv4             DNSCrypt stockholm  7ms     29ms    NA      12.80   0.00    7.13   
njalla-doh                           DoH      ?          17ms    28ms    NA      5.81    0.00    16.70  
cs-norway                            DNSCrypt norway     15ms    30ms    NA      7.38    0.00    14.55  
scaleway-ams                         DNSCrypt FR         26ms    26ms    NA      0.63    0.00    25.60  
dnscry.pt-tuusula-ipv4               DNSCrypt tuusula    1ms     38ms    NA      20.45   0.00    1.30   
dns.digitalsize.net                  DoH      ?          26ms    31ms    NA      2.50    0.00    26.22 
```

## Recommended dnscrypt-proxy config block

The script generates a ready-to-paste TOML block from the top scoring servers:

```toml
server_names = [
    'cloudflare',
    'nextdns-ultralow',
    'quad9-dnscrypt-ip4-nofilter-pri',
    'cs-swe',
    'cs-norway',
    'njalla-doh',
]


lb_strategy = 'wp2'
lb_estimator = true
cache = false
```

`wp2` (weighted power-of-two) is the recommended load balancer in dnscrypt-proxy 2.1.5+. It picks two random servers from the pool and routes to the faster one, with weights derived from the moving-average RTT estimator. Better than plain `p2` for heterogeneous resolver pools.

## Methodology limitations (honest list)

- **Single-run noise**: one benchmark is one data point. Re-run at peak and off-peak hours before finalizing a config.
- **Geographic bias**: results reflect your VPS location and routing. A server that's 200 ms away from you might be 5 ms away from your users if they're elsewhere.
- **The pacing changes the burst test**: with `random_sleep` enabled, the "parallel burst" is closer to "moderate concurrency". This is intentional — actual bursts often produce rate-limit responses that pollute the score.
- **Cold-start is approximated**: we measure first-query latency after the proxy reports ready. Some resolvers do additional warmup that isn't visible in logs.
- **Cache test is loopback**: the script measures dnscrypt-proxy → upstream. It does not simulate AGH and Unbound being in the path. The results are the *input quality* for that pipeline.

## Contributing

Issues and PRs welcome. Especially valuable:

- Additional pinned resolvers worth testing
- Geo-detection improvements (the regex set is heuristic)
- Better convergence detection for Phase 1 discovery
- macOS / BSD compatibility fixes if you find any

## 🤖 Development Process

This project follows a human-driven architecture approach with AI-assisted
implementation. I do not write native code; I engineer the systems, the
logic, and the validation methodology.

The production syntax, scoring weights, and edge-case handling were refined
through iterative collaboration with multiple AI models:

- **Anthropic Claude (Opus 4.7)** — primary architect for methodology fixes,
  code review, and statistical reasoning
- **Google Gemini** — secondary review and refactoring assistance
- **OpenAI ChatGPT / Codex** — early prototyping and bash idiom checks

The AI models acted as high-level tools to translate years of operational
DNS resolver experience into clean, conformant Bash. All design decisions,
methodology choices, and the v7 → v8 honesty correction were human-led.

If you find a bug, the responsibility is mine. If you find a clean idiom,
credit the swarm.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [DNSCrypt/dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) project for the underlying tool and resolver list
- Authoritative DNS operators (Cloudflare, Google, Amazon, Microsoft, Wikimedia) who serve our recursion probes without complaint
