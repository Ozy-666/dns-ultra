# Changelog

All notable changes to dns-ultra are documented here.

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
