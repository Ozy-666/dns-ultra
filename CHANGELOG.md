# Changelog

All notable changes to dns-ultra are documented here.

## [8.2.4] — 2026-05-18

### Added
- **Early bail before cold-start**: Cold-start measurements now run only after fast-path confirms the server is alive. Previously, cold-start (up to 3 × 25s timeouts) ran before fast-path, wasting ~75s on dead servers. Dead servers are now skipped immediately after fast-path fails.
- **Color-coded score on profiling line**: Score label is green (< 20), yellow (20–50), or red (> 50) so winners and losers are visible while profiling runs, without waiting for the final table.
- **ETA on profiling line**: After the first server completes, each subsequent line shows `~Xm left` based on average time per server so far.
- **Cold-start cert-fail note**: When all cold-start samples fail (COLDSTART=999ms), the profiling line appends `(cold: cert-fail)` so users know this is a DNSCrypt certificate fetch failure, not a slow resolver.
- **Failed server summary**: After profiling completes, a short list of any servers that failed (proxy not ready, or 0 fast-path queries) is printed with the failure reason.
- **DoH-aware per-server detection**: Each server in the Phase 2 profiling loop is classified as DoH if its protocol tag or name contains `doh` (case-insensitive). Sets an `IS_DOH` flag consumed by all downstream measurement functions, warmup loops, and burst tests.
- **`doh_sleep()` micro-delay**: Lightweight 15ms fixed delay applied between every DoH query (fastpath, recursion, warmup, sequential burst). Prevents back-to-back request flooding on strict endpoints (Quad9, Cloudflare DoH) while keeping benchmark duration minimal. DNSCrypt servers bypass this entirely.
- **`DISABLED_SERVERS` list + `disabled_server_names` in config**: All eight Quad9 DoH variants (`quad9-doh-*`) are permanently excluded from every dnscrypt-proxy instance spawned by the benchmark. Benchmarking confirmed 4–6% sustained packet loss on Quad9 DoH from VPS nodes while the identical Quad9 DNSCrypt servers show 0.00% loss on the same link. Root cause: Quad9's DoH edge enforces per-session HTTP/2 stream limits that stateless DNSCrypt/UDP is simply not subject to. Excluding them prevents them from ever appearing in the recommended config.
- **VERSION string**: Script now declares `VERSION="8.2.4"` for explicit runtime identification.

### Changed
- **DoH parallel burst forced sequential**: `measure_parallel_burst` accepts a new `is_doh` parameter and passes `-P 1` to `xargs` for DoH upstreams, preventing concurrent connection saturation that caused Quad9 DoH to show 20% packet loss. DNSCrypt remains fully parallelised at `PAR_BURST_JOBS`.
- **`measure_parallel_burst` sleep command**: DoH workers use `sleep 0.015`; DNSCrypt workers retain the original `awk`-seeded uniform jitter (0–100ms).

### Fixed
- **`google` pinned server silently excluded**: `require_nolog = true` and `require_nofilter = true` in every spawned dnscrypt-proxy config caused Google DNS to be skipped in both discovery and per-server profiling — Google's SDNS stamp declares `nolog = 0`. Both flags changed to `false` since this is a benchmark tool, not a privacy filter. Pinned servers like `google` now appear correctly.
- **Recommended config score threshold**: Config output now applies a `score ≤ 50` filter in addition to the existing reliability check. Previously, servers marked `ok` with high scores (e.g. 74.70 with R_P95=918ms, or 97.31 with F_P95=221ms) could appear in `server_names` — they are now excluded.
- **UI bracket padding** (`[DoH      Anycast]` → `[DoH Anycast]`): Candidate list and Phase 2 profiling line now build a combined `proto+geo` tag and render it with a single tight `[%s]` specifier — no interior padding gaps.
- **Table PROTO/GEO columns merged**: Sections 3 and 4 ranking tables replace the separate `%-8s PROTO` + `%-10s GEO` columns with a single `%-18s` combined column, eliminating dead whitespace for short protocol names (e.g. `DoH`).
- **Unbound color variables** (`set -u` crash): Moved `COLORS` block above `require_bin` and the dnscrypt-proxy pre-flight check so `${RED}`/`${NC}` are always defined before first use.
- **GEO_MAP subshell isolation**: Converted pipe-into-`while` loops to process substitution (`< <(...)`) in the candidate display and tail-offender sections so the associative array is visible inside the loop body.
- **Table alignment truncation**: All four `printf` format strings changed from `%-36s` to `%-36.36s` — server names longer than 36 characters are hard-truncated instead of pushing columns out of alignment.
- **Unknown geo label suppressed**: Servers with no geo match now show a blank field instead of `?`.

## [8.2.3] — 2026-05-18

### Added
- **Smart Binary Auto-Detection**: Added robust path discovery that scans both system `$PATH` and manual/portable installation structures (such as official unpacked release folders like `/opt/dnscrypt-proxy/linux-x86_64/`).
- **Pre-flight Health Check**: Implemented strict validation that tests the discovered binary for existence and execution permissions before spawning background processes, avoiding silent logging failures.

### Fixed (hotfixes)
- **Unbound color variables**: Moved the `COLORS` block to immediately after `set -u` so that `require_bin` and the dnscrypt-proxy pre-flight check can reference `${RED}`/`${NC}` without hitting a `set -u` "unbound variable" crash when a dependency is missing.
- **GEO_MAP subshell isolation**: Converted the candidate display loop and the tail-offender loop from pipe-into-`while` (which spawns a subshell where associative arrays are invisible) to process substitution (`< <(...)`), restoring correct geo-location labels in both sections.
- **Table alignment truncation**: Changed `%-36s` to `%-36.36s` in all four `printf` format strings so that server names longer than 36 characters are hard-truncated, preventing column misalignment in the ranking tables.


## [8.2.1] — 2026-05-17

### Methodology overhaul (the honest version)

This release fixes the fundamental bias of v7 and v8.0 where uncached
authoritative walks dominated the score and made Quad9, Cloudflare and Google
rank below noisier regional resolvers.

### Added
- **Ethical query pacing**: 50-150 ms random jitter between queries prevents
  triggering rate limits on strict resolvers (Quad9, NextDNS) and accurately
  emulates Unbound's sequential cache-miss behavior.
- **Two-stage Ctrl+C handler**: first interrupt finishes current test cleanly;
  second interrupt force-kills. Prevents temp directory corruption.
- **Cold-start cap**: penalty capped at 100 ms so failed DNSCrypt cert fetches
  (returning 999 ms sentinel) don't dominate the score.
- **Markdown report export** for copy-pasting into issues and PRs.
- **`--quick`** flag for fast iteration (~3 min vs ~15 min).
- **`--top N`** to limit final ranking rows.
- **Auto-detection of dnscrypt-proxy** from common install paths.

### Changed
- **Scoring formula (v8.2 Unbound Cache-Aware)**:
  - Fastpath jitter weight raised from 0.10 to 0.30 (consistency matters more
    than raw median when there's a cache in front)
  - Recursion subscore multiplied by 0.25 overall (Unbound caches misses)
  - Fastpath median weight lowered from 0.45 to 0.30
  - Parallel burst weight reduced from 0.06 to 0.010 (realistic for home stacks)
  - Cold-start weight halved from 0.02 to 0.01
- **Recursion targets**: restricted to large CDN operators only (Cloudflare,
  Google, Amazon, Microsoft, Wikipedia). Removed iana.org, kernel.org, ietf.org
  from random-subdomain probing to avoid abusing small operators.
- **Parallel burst workers** reduced from 8 to 3 (matches realistic home use).
- **Cold-start timeout** raised from 12 s to 25 s to accommodate slow
  DNSCrypt certificate fetches.
- **Loss penalty squared**: `loss² × 3` for fastpath, `loss × 10 × 0.25` for
  recursion. Forgives single-packet noise, punishes sustained failure.
- **Recommended config now uses `lb_strategy = 'wp2'`** (weighted
  power-of-two-choices, dnscrypt-proxy 2.1.5+).

### Fixed
- **Broken ANSI color escapes**: five color constants in v8.0 were missing the
  `[` character, producing literal "32m" prefixes in all output. Detection
  added for non-TTY output to disable colors when piped.
- **Validation of FAST_SUCCESS / FAST_TOTAL**: empty-variable arithmetic no
  longer throws errors when a resolver fails entirely.

## [8.1.0] — 2026-05-17 (internal)

Internal iteration. Identified the methodology issues that v8.2 fixed.

## [8.0.0] — 2026-05-16

Initial public iteration. Separated fastpath from recursion profiles. Had
known bias toward noisy regional resolvers due to insufficient recursion
downweighting and linear loss penalty. Superseded.

## [7.x] — pre-history

Mixed-score benchmark. Did not separate cached fast-path lookups from
authoritative-walk tail latency.
