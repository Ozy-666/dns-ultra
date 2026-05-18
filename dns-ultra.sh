#!/usr/bin/env bash
# ============================================================================
# dns-ultra.sh — Upstream Resolver Profiler for AGH -> Unbound -> dnscrypt-proxy
# ============================================================================
#
# Goal:
#   Select reliable upstream resolvers for dnscrypt-proxy behind a local caching
#   chain. This script avoids the v7 bias where uncached authoritative walks
#   dominated the score, misrepresenting excellent fast-path resolvers.
#
# Features:
#   - Dual profile testing (Fastpath vs Recursion).
#   - Unbound Cache-Aware scoring: Fastpath is king, Recursion is a minor factor.
#   - Ethical pacing (50ms delays) to prevent triggering Rate-Limits on strict
#     resolvers (Quad9, NextDNS), emulating Unbound's real cache-miss behavior.
#   - Jitter-Dominant scoring to penalize unstable VPS resolvers.
#   - Cold-start measurement with extended timeouts for DNSCrypt cert fetches.
#   - Graceful Ctrl+C handling to prevent temp directory corruption.
#
# Requirements:
#   bash, dig, awk, sort, sed, grep, openssl, jq, xargs
# ============================================================================

set -u
# Force C locale to ensure dig, awk, and sort output predictable English strings
export LC_ALL=C

# ============================================================================
# COLORS  (defined first so require_bin and pre-flight checks can use them)
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

QUICK_MODE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "DNSCRYPT ULTRA-BENCH — Public Resolver Upstream Profiler"
            echo ""
            echo "Options:"
            echo "  --quick           Fast benchmark (~3 min): 8 candidates, fewer rounds"
            echo "  -h, --help        Show this help and exit"
            echo ""
            echo "Environment variables:"
            echo "  PROXY_BIN         Path to dnscrypt-proxy (default: /opt/dnscrypt2.1.5/dnscrypt-proxy)"
            echo "  TOP_PHASE2        Number of RTT-top servers to profile (default: 24, quick: 8)"
            echo "  DNSCRYPT_CACHE    Set to 'true' if no external caching layer is used (default: false)"
            exit 0
            ;;
        --quick)
            QUICK_MODE="true"
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Apply quick mode by reducing default parameters BEFORE they're read
if [ "$QUICK_MODE" = "true" ]; then
    TOP_PHASE2="${TOP_PHASE2:-6}"
    FASTPATH_ROUNDS="${FASTPATH_ROUNDS:-3}"
    RECURSION_ROUNDS="${RECURSION_ROUNDS:-2}"
    SEQ_BURST_QUERIES="${SEQ_BURST_QUERIES:-10}"
    PAR_BURST_QUERIES="${PAR_BURST_QUERIES:-10}"
    COLDSTART_SAMPLES="${COLDSTART_SAMPLES:-1}"
    WARMUP_QUERIES="${WARMUP_QUERIES:-3}"
    TIMEOUT="${TIMEOUT:-30}"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

# ============================================================================
# REQUIREMENTS
# ============================================================================

require_bin() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}Missing dependency:${NC} $1"
        exit 1
    }
}

require_bin dig
require_bin awk
require_bin sort
require_bin sed
require_bin grep
require_bin openssl
require_bin jq
require_bin xargs

# --- AUTO-DETECT DNSCRYPT-PROXY ---
if [ -z "${PROXY_BIN:-}" ]; then
    # Check if it's in standard PATH
    if command -v dnscrypt-proxy >/dev/null 2>&1; then
        PROXY_BIN="$(command -v dnscrypt-proxy)"
    else
        # Scan common manual installation paths
        COMMON_PATHS=(
            "/opt/dnscrypt2.1.5/dnscrypt-proxy"
            "/opt/dnscrypt2.1.15/dnscrypt-proxy"
            "/opt/dnscrypt-proxy/linux-x86_64/dnscrypt-proxy"
            "/opt/dnscrypt-proxy/linux-arm64/dnscrypt-proxy"
            "/opt/dnscrypt-proxy/dnscrypt-proxy"
            "/opt/linux-x86_64/dnscrypt-proxy"
            "/usr/local/bin/dnscrypt-proxy"
            "/usr/bin/dnscrypt-proxy"
            "/bin/dnscrypt-proxy"
        )
        for p in "${COMMON_PATHS[@]}"; do
            if [ -x "$p" ]; then
                PROXY_BIN="$p"
                break
            fi
        done
    fi
fi

# Final check
if [ -z "${PROXY_BIN:-}" ] || [ ! -x "$PROXY_BIN" ]; then
    echo -e "${RED}ERROR: dnscrypt-proxy binary not found.${NC}"
    echo "Auto-detection failed. Please set PROXY_BIN explicitly:"
    echo "  PROXY_BIN=/path/to/dnscrypt-proxy ./dns-ultra.sh"
    exit 1
fi

LISTEN_IP="${LISTEN_IP:-127.0.0.1}"
BASE_PORT="${BASE_PORT:-55000}"

# Discovery breadth and Phase 2 depth
TOP_PHASE2="${TOP_PHASE2:-24}"
TIMEOUT="${TIMEOUT:-120}"
RTT_MAX_PHASE1="${RTT_MAX_PHASE1:-800}"

# Measurement parameters
FASTPATH_ROUNDS="${FASTPATH_ROUNDS:-5}"
RECURSION_ROUNDS="${RECURSION_ROUNDS:-6}"
WARMUP_QUERIES="${WARMUP_QUERIES:-8}"
COLDSTART_SAMPLES="${COLDSTART_SAMPLES:-3}"

# Burst test parameters
SEQ_BURST_QUERIES="${SEQ_BURST_QUERIES:-35}"
PAR_BURST_QUERIES="${PAR_BURST_QUERIES:-30}"
PAR_BURST_JOBS="${PAR_BURST_JOBS:-3}"

# Timeouts
PROXY_TIMEOUT_MS="${PROXY_TIMEOUT_MS:-2500}"
DIG_TIMEOUT_SEC="${DIG_TIMEOUT_SEC:-4}"

# Keep false if an external caching layer (Unbound) sits above dnscrypt-proxy
DNSCRYPT_CACHE="${DNSCRYPT_CACHE:-false}"

# Providers worth testing even if their discovery RTT is not top-N
PINNED_SERVERS=(
    "nic.cz"
)

# FASTPATH: Fixed real names. These should generally hit upstream resolver cache.
FASTPATH_DOMAINS=(
    "google.com"
    "cloudflare.com"
    "github.com"
    "wikipedia.org"
    "microsoft.com"
    "apple.com"
    "youtube.com"
    "telegram.org"
    "delfi.lv"
    "ss.com"
    "yandex.ru"
    "habr.com"
    "ietf.org"
    "iana.org"
    "kernel.org"
)

# RECURSION: Random subdomains. Use ONLY large CDN/Anycast operators.
# Sending random subdomains to small auth servers is abusive.
RECURSION_BASE_DOMAINS=(
    "cloudflare.com"
    "google.com"
    "amazon.com"
    "wikipedia.org"
    "microsoft.com"
)

# Burst base domains
BURST_BASE_DOMAINS=(
    "cloudflare.com"
    "google.com"
    "github.com"
    "wikipedia.org"
    "amazon.com"
)

# ============================================================================
# TEMPORARY DIRECTORY & CLEANUP
# ============================================================================

BENCH_DIR=$(mktemp -d)
RESULTS_DIR="$BENCH_DIR/results"
mkdir -p "$RESULTS_DIR"

ACTIVE_PIDS=()
INTERRUPTED=0

# SIGINT handler: just set the flag on first Ctrl+C
handle_interrupt() {
    if [ $INTERRUPTED -eq 0 ]; then
        echo ""
        echo -e "${YELLOW}Interrupted! Finishing current test and cleaning up...${NC}"
        INTERRUPTED=1
    else
        # Second Ctrl+C, force kill proxy if stuck
        for pid in "${ACTIVE_PIDS[@]}"; do
            kill -9 "$pid" 2>/dev/null
        done
    fi
}

# EXIT handler: runs when script exits normally or after interrupt
cleanup() {
    for pid in "${ACTIVE_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${ACTIVE_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$BENCH_DIR"
}

trap handle_interrupt INT TERM
trap cleanup EXIT

SECONDS=0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

write_config() {
    local cfg="$1"
    local port="$2"
    local server_name="${3:-}"

    if [ -n "$server_name" ]; then
        local server_line="server_names = ['$server_name']"
    else
        local server_line="server_names = []"
    fi

    cat > "$cfg" <<EOF
listen_addresses = ['${LISTEN_IP}:${port}']
${server_line}

require_dnssec = false
require_nolog = true
require_nofilter = true

ipv6_servers = false
block_ipv6 = true

force_tcp = false

cache = ${DNSCRYPT_CACHE}

netprobe_timeout = 20
timeout = ${PROXY_TIMEOUT_MS}

lb_strategy = 'first'
lb_estimator = true

dnscrypt_servers = true
doh_servers = true
odoh_servers = false

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md']
    cache_file = '$BENCH_DIR/resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
EOF
}

wait_proxy_log_ready() {
    local pid="$1"
    local log="$2"
    local timeout_s="${3:-12}"
    local waited=0

    while kill -0 "$pid" 2>/dev/null; do
        if grep -qiE "now listening|dnscrypt-proxy is ready|plugin.*started|listening to" "$log" 2>/dev/null; then
            return 0
        fi
        if [ "$waited" -ge "$timeout_s" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

dig_query_time() {
    local port="$1"
    local domain="$2"
    local out status qtime

    out=$(dig @"$LISTEN_IP" -p "$port" "$domain" A +time="$DIG_TIMEOUT_SEC" +tries=1 +stats 2>/dev/null)
    status=$(printf "%s\n" "$out" | awk -F'[:, ]+' '/status:/ {print $6; exit}')
    qtime=$(printf "%s\n" "$out" | awk '/Query time:/ {print $4; exit}')

    if [[ "$qtime" =~ ^[0-9]+$ ]] && [[ "$status" =~ ^(NOERROR|NXDOMAIN)$ ]]; then
        printf "%s\n" "$qtime"
        return 0
    fi

    return 1
}

calc_count() {
    awk 'NF {n++} END {print n+0}'
}

calc_median() {
    sort -n | awk '{a[NR]=$1}
    END {
        if (NR == 0) { print 999; exit }
        if (NR % 2) print a[(NR+1)/2]
        else printf "%.2f", (a[NR/2] + a[NR/2+1]) / 2
    }'
}

calc_avg() {
    awk '{sum += $1; n++} END {if (n == 0) print 999; else printf "%.2f", sum/n}'
}

calc_percentile() {
    local pct="$1"
    sort -n | awk -v pct="$pct" '{a[NR]=$1}
    END {
        if (NR == 0) { print 999; exit }
        idx = int(NR * pct + 0.999999)
        if (idx < 1) idx = 1
        if (idx > NR) idx = NR
        print a[idx]
    }'
}

calc_stddev() {
    awk '{x[NR]=$1; sum+=$1}
    END {
        if (NR == 0) {print 999; exit}
        if (NR == 1) {print 0; exit}
        mean=sum/NR
        for(i=1;i<=NR;i++) sq+=(x[i]-mean)^2
        printf "%.2f", sqrt(sq/NR)
    }'
}

calc_trimmed_avg() {
    sort -n | awk '
    {a[NR]=$1}
    END {
        if (NR == 0) {print 999; exit}
        lo = int(NR * 0.10) + 1
        hi = int(NR * 0.90)
        if (hi < lo) {lo = 1; hi = NR}
        for (i=lo; i<=hi; i++) {sum += a[i]; n++}
        printf "%.2f", sum/n
    }'
}
random_sleep() {
    sleep $(awk -v seed="$RANDOM" 'BEGIN{srand(seed); printf "%.3f", 0.05 + rand() * 0.1}')
}
doh_sleep() {
    # 24-bit CSPRNG entropy → power-curve right-skewed delay (80–450ms).
    # Mimics organic browser HTTPS inter-request gaps; evades DoH rate-limit detectors.
    local raw
    raw=$(openssl rand -hex 3)
    sleep $(awk -v hex="$raw" 'BEGIN {
        val    = strtonum("0x" hex)
        norm   = val / 16777215.0
        shaped = norm ^ 1.7
        printf "%.3f", 0.080 + shaped * 0.370
    }')
}
safe_name() {
    printf "%s" "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

geo_build_map() {
    declare -gA GEO_MAP

    if [ ! -f "$BENCH_DIR/resolvers.md" ]; then
        return 0
    fi

    awk '
        /^## / {
            if (name != "") print name "|" location
            name = substr($0, 4)
            location = ""

            if (match(name, /^dnscry\.pt-[a-z0-9]+/)) {
                chunk = substr(name, 11, RLENGTH-10)
                sub(/-ipv[46]$/, "", chunk)
                location = chunk
            }
            else if (match(name, /^cs-[a-z]+/)) {
                chunk = substr(name, 4)
                sub(/-?ipv[46].*/, "", chunk)
                location = chunk
            }
            else if (name ~ /cloudflare/) { location = "Anycast" }
            else if (name ~ /quad9/) { location = "Anycast" }
            else if (name ~ /nextdns/) { location = "Anycast" }
            else if (name ~ /google/) { location = "Anycast" }
            else if (name ~ /adguard/) { location = "Anycast" }
            else if (name ~ /controld/) { location = "Anycast" }
            else if (name ~ /mullvad/) { location = "Anycast" }
            else if (name ~ /^dns0/) { location = "Anycast" }
            else if (name ~ /^scaleway/) { location = "FR" }
            else if (name ~ /^yandex/) { location = "RU" }
            next
        }
        name != "" && location == "?" {
            text = $0
            if (match(text, /[Aa]nycast/)) { location = "Anycast"; next }
            if (match(text, /[Hh]osted in [A-Za-z][^,]*, [A-Za-z]+/)) {
                chunk = substr(text, RSTART, RLENGTH)
                sub(/^.*, /, "", chunk)
                sub(/\..*$/, "", chunk)
                location = chunk
                next
            }
            if (match(text, /[Ll]ocated in [A-Za-z]+/)) {
                chunk = substr(text, RSTART, RLENGTH)
                sub(/^[Ll]ocated in /, "", chunk)
                location = chunk
                next
            }
        }
        END {
            if (name != "") print name "|" location
        }
    ' "$BENCH_DIR/resolvers.md" > "$BENCH_DIR/geo.txt" 2>/dev/null || true

    while IFS='|' read -r srv loc; do
        loc="${loc:0:10}"
        GEO_MAP["$srv"]="$loc"
    done < "$BENCH_DIR/geo.txt"
}

measure_domain_set() {
    local port="$1"
    local mode="$2"
    local rounds="$3"
    local out_file="$4"
    local domain_report="$5"
    shift 5
    local domains=("$@")

    : > "$out_file"
    : > "$domain_report"

    local total=0
    local success=0
    local domain domain_file q rand qtime n med p95 avg

    for domain in "${domains[@]}"; do
        domain_file="$BENCH_DIR/domain_${mode}_$(safe_name "$domain").txt"
        : > "$domain_file"

        for _ in $(seq 1 "$rounds"); do
            if [ $INTERRUPTED -eq 1 ]; then break 2; fi

            if [ "$mode" = "recursion" ]; then
                rand=$(openssl rand -hex 5)
                q="${rand}.${domain}"
            else
                q="$domain"
            fi

            total=$((total + 1))
            if qtime=$(dig_query_time "$port" "$q"); then
                success=$((success + 1))
                echo "$qtime" >> "$out_file"
                echo "$qtime" >> "$domain_file"
            fi
            # Ethical pacing: DNSCrypt uses light uniform jitter; DoH uses
            # CSPRNG-seeded non-linear delay to evade HTTP/2 rate-limit detectors.
            if [ "${IS_DOH:-0}" -eq 1 ]; then doh_sleep; else random_sleep; fi
        done

        n=$(calc_count < "$domain_file")
        med=$(calc_median < "$domain_file")
        p95=$(calc_percentile 0.95 < "$domain_file")
        avg=$(calc_avg < "$domain_file")
        printf "%s|%s|%s|%s|%s\n" "$domain" "$n" "$med" "$avg" "$p95" >> "$domain_report"
    done

    printf "%s|%s\n" "$success" "$total"
}

measure_seq_burst() {
    local port="$1"
    local out_file="$2"
    : > "$out_file"

    local base_count="${#BURST_BASE_DOMAINS[@]}"
    local rand base domain qtime

    for _ in $(seq 1 "$SEQ_BURST_QUERIES"); do
        if [ $INTERRUPTED -eq 1 ]; then break; fi

        rand=$(openssl rand -hex 4)
        base="${BURST_BASE_DOMAINS[$((RANDOM % base_count))]}"
        domain="${rand}.${base}"

        if qtime=$(dig_query_time "$port" "$domain"); then
            echo "$qtime" >> "$out_file"
        fi
        if [ "${IS_DOH:-0}" -eq 1 ]; then doh_sleep; else random_sleep; fi
    done
}

measure_parallel_burst() {
    local port="$1"
    local out_file="$2"
    local is_doh="${3:-0}"
    local domains_file="$BENCH_DIR/par_domains_${port}.txt"

    : > "$out_file"
    : > "$domains_file"

    local base_count="${#BURST_BASE_DOMAINS[@]}"
    local rand base sleep_cmd

    for _ in $(seq 1 "$PAR_BURST_QUERIES"); do
        rand=$(openssl rand -hex 4)
        base="${BURST_BASE_DOMAINS[$((RANDOM % base_count))]}"
        echo "${rand}.${base}" >> "$domains_file"
    done

    if [ "$is_doh" -eq 1 ]; then
        # DoH: CSPRNG-seeded non-linear delay (80–450ms right-skewed)
        sleep_cmd='raw=$(openssl rand -hex 3); sleep $(awk -v hex="$raw" '"'"'BEGIN{val=strtonum("0x" hex);norm=val/16777215.0;shaped=norm^1.7;printf "%.3f",0.080+shaped*0.370}'"'"')'
    else
        # DNSCrypt: original fast uniform jitter (0–100ms)
        sleep_cmd='sleep $(awk -v seed="$RANDOM" '"'"'BEGIN{srand(seed);printf "%.3f",rand()*0.1}'"'"')'
    fi

    xargs -P "$PAR_BURST_JOBS" -I{} \
        sh -c "$sleep_cmd; dig @$LISTEN_IP -p $port {} A +time=$DIG_TIMEOUT_SEC +tries=1 +stats 2>/dev/null" \
        < "$domains_file" |
        awk '/Query time:/ {print $4}' |
        awk '$1 ~ /^[0-9]+$/ {print $1}' > "$out_file"
}

# ============================================================================
# SCORING FORMULA (Unbound Cache-Aware)
# ============================================================================
score_server() {
    local fast_med="$1"
    local fast_p95="$2"
    local fast_jit="$3"
    local fast_loss="$4"
    local rec_med="$5"
    local rec_p95="$6"
    local rec_loss="$7"
    local seq_p95="$8"
    local par_p95="$9"
    local cold="${10}"

    awk \
        -v fmed="$fast_med" \
        -v fp95="$fast_p95" \
        -v fjit="$fast_jit" \
        -v floss="$fast_loss" \
        -v rmed="$rec_med" \
        -v rp95="$rec_p95" \
        -v rloss="$rec_loss" \
        -v sp95="$seq_p95" \
        -v pp95="$par_p95" \
        -v cold="$cold" \
    'BEGIN {
        # 1. Cap cold start penalty: Anything over 100ms is capped.
        cold_val = cold;
        if (cold_val > 100) cold_val = 100;

        # 2. FASTPATH: The absolute king (Unbound serves this 90% of the time).
        # Jitter is critical here to prevent Unbound cache misses.
        fast = (fmed * 0.30) + (fp95 * 0.25) + (fjit * 0.30) + (floss * floss * 3)
        
        # 3. RECURSION: Must be a minor tie-breaker, not a dominant factor.
        # Unbound caches this, so we only care if it is catastrophically bad.
        # Weight drastically reduced by 0.25 multiplier.
        # Note: Strict DNSSEC resolvers (Quad9) naturally show higher P95 here
        # due to NSEC validation on NXDOMAIN responses. This is a security feature.
        recursion = ((rmed * 0.10) + (rp95 * 0.12) + (rloss * 10)) * 0.25
        
        # 4. BURST: Sequential matters, parallel is negligible for home routers.
        burst = (sp95 * 0.030) + (pp95 * 0.010)
        
        # 5. COLD: Minimal weight.
        coldpart = cold_val * 0.01
        
        score = fast + recursion + burst + coldpart
        printf "%.2f|%.2f|%.2f|%.2f|%.2f", score, fast, recursion, burst, coldpart
    }'
}

# ============================================================================
# HEADER
# ============================================================================

echo ""
echo -e "${WHITE}============================================================================${NC}"
echo -e "${WHITE}        DNSCRYPT ULTRA-BENCH  Public Resolver Upstream Profiler${NC}"
echo -e "${WHITE}============================================================================${NC}"
echo ""
echo -e "${CYAN}Target stack:${NC} AdGuardHome -> Unbound(cache) -> dnscrypt-proxy"
echo -e "${CYAN}Purpose:${NC} Choose reliable dnscrypt-proxy upstreams for your secure gateway"
echo ""
echo -e "${CYAN}Profiles:${NC}"
echo "  FASTPATH  : Fixed domains after warmup; main real-use signal"
echo "  RECURSION : Random subdomains; authoritative-walk tail signal"
echo "  BURST     : Sequential and parallel burst behavior"
echo "  COLDSTART : First real query after proxy starts listening"
echo ""
echo -e "${DIM}Started: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo ""

# ============================================================================
# PHASE 1: DISCOVERY
# ============================================================================

DISCOVERY_CFG="$BENCH_DIR/discovery.toml"
DISCOVERY_LOG="$BENCH_DIR/discovery.log"

write_config "$DISCOVERY_CFG" "$BASE_PORT" ""

echo -e "${YELLOW}[1/6]${NC} Discovery benchmark"
echo -e "      Starting dnscrypt-proxy on ${LISTEN_IP}:${BASE_PORT}..."

"$PROXY_BIN" -config "$DISCOVERY_CFG" > "$DISCOVERY_LOG" 2>&1 &
DISCOVERY_PID=$!
ACTIVE_PIDS+=("$DISCOVERY_PID")

sleep 2

if ! kill -0 "$DISCOVERY_PID" 2>/dev/null; then
    echo -e "${RED}ERROR:${NC} dnscrypt-proxy failed to start"
    cat "$DISCOVERY_LOG"
    exit 1
fi

# Reset SECONDS for accurate execution tracking
SECONDS=0
LAST_DISCOVERED_COUNT=0
STABLE_COUNT=0

while kill -0 "$DISCOVERY_PID" 2>/dev/null; do
    if [ $INTERRUPTED -eq 1 ]; then
        kill "$DISCOVERY_PID" 2>/dev/null
        break
    fi

    if [ "$SECONDS" -ge "$TIMEOUT" ]; then
        echo -e "      ${DIM}Reached max discovery time (${TIMEOUT}s)${NC}"
        kill "$DISCOVERY_PID" 2>/dev/null || true
        break
    fi

    CURRENT_COUNT=$(grep -cE "\] OK .* rtt: [0-9]+ms" "$DISCOVERY_LOG" 2>/dev/null || echo 0)
    
    if [ "$CURRENT_COUNT" -eq "$LAST_DISCOVERED_COUNT" ]; then
        STABLE_COUNT=$((STABLE_COUNT + 1))
        if [ "$STABLE_COUNT" -ge 2 ] && [ "$SECONDS" -ge 30 ]; then
            echo -e "      ${DIM}Discovery converged (server count stable for 10s)${NC}"
            kill "$DISCOVERY_PID" 2>/dev/null || true
            break
        fi
    else
        STABLE_COUNT=0
        LAST_DISCOVERED_COUNT="$CURRENT_COUNT"
    fi

    echo "      Scanning resolvers... ${SECONDS}s elapsed, ${CURRENT_COUNT} reachable"
    sleep 5
done

wait "$DISCOVERY_PID" 2>/dev/null || true
echo ""

grep -E "\] OK .* rtt: [0-9]+ms" "$DISCOVERY_LOG" |
    sed 's/.*\[\(.*\)\] OK (\([^)]*\)) - rtt: \([0-9]*\)ms.*/\3|\1|\2/' |
    sort -t'|' -k1 -n |
    awk -F'|' '!seen[$2]++' |
    awk -F'|' -v max="$RTT_MAX_PHASE1" '$1 >= 1 && $1 <= max' > "$BENCH_DIR/phase1_all.txt"

FOUND=$(wc -l < "$BENCH_DIR/phase1_all.txt")

if [ "$FOUND" -lt 5 ]; then
    echo -e "${RED}Only $FOUND servers found. Network issue or discovery incomplete.${NC}"
    exit 1
fi

geo_build_map

# Build candidate list: top by RTT + pinned trustworthy providers if discovered
head -n "$TOP_PHASE2" "$BENCH_DIR/phase1_all.txt" > "$BENCH_DIR/phase2_candidates.tmp"

for pinned in "${PINNED_SERVERS[@]}"; do
    awk -F'|' -v srv="$pinned" '$2 == srv {print; exit}' "$BENCH_DIR/phase1_all.txt" >> "$BENCH_DIR/phase2_candidates.tmp"
done

awk -F'|' '!seen[$2]++' "$BENCH_DIR/phase2_candidates.tmp" > "$BENCH_DIR/phase2_candidates.txt"
CANDIDATE_COUNT=$(wc -l < "$BENCH_DIR/phase2_candidates.txt")

echo -e "${GREEN}      Servers usable:${NC} $FOUND (RTT 1-${RTT_MAX_PHASE1}ms)"
echo -e "${CYAN}      Phase 2 candidates:${NC} $CANDIDATE_COUNT (${TOP_PHASE2} RTT-top plus pinned if available)"
echo ""

while IFS='|' read -r rtt name proto; do
    geo="${GEO_MAP[$name]:-}"
    printf "      ${GREEN}%4sms${NC}  %-42s ${DIM}[%-8s %s]${NC}\n" "$rtt" "$name" "$proto" "$geo"
done < <(head -n "$CANDIDATE_COUNT" "$BENCH_DIR/phase2_candidates.txt")
echo ""

# ============================================================================
# PHASE 2: DEEP PROFILING
# ============================================================================

echo -e "${YELLOW}[2/6]${NC} Deep profiling"
echo -e "      FASTPATH sample:  ${#FASTPATH_DOMAINS[@]} domains × ${FASTPATH_ROUNDS} rounds"
echo -e "      RECURSION sample: ${#RECURSION_BASE_DOMAINS[@]} domains × ${RECURSION_ROUNDS} rounds"
echo -e "      Burst: sequential=${SEQ_BURST_QUERIES}, parallel=${PAR_BURST_QUERIES} @ jobs=${PAR_BURST_JOBS}"
echo ""

FINAL_TXT="$RESULTS_DIR/final.txt"
DOMAIN_TAILS="$RESULTS_DIR/domain_tails.txt"
: > "$FINAL_TXT"
: > "$DOMAIN_TAILS"

COUNT=0

while IFS='|' read -r rtt name proto; do
    if [ $INTERRUPTED -eq 1 ]; then break; fi

    COUNT=$((COUNT + 1))
    PORT=$((BASE_PORT + COUNT))
    GEO="${GEO_MAP[$name]:-}"
    SAFE=$(safe_name "$name")

    IS_DOH=0
    if [[ "${proto,,}" == *"doh"* ]] || [[ "${name,,}" == *"doh"* ]]; then
        IS_DOH=1
    fi

    printf "      Profiling [%2d/%d] %-42s ${DIM}[%s]${NC} " "$COUNT" "$CANDIDATE_COUNT" "$name" "$GEO"

    CFG="$BENCH_DIR/${SAFE}.toml"
    LOG="$BENCH_DIR/${SAFE}.log"
    write_config "$CFG" "$PORT" "$name"

    # Cold-start: Start fresh process, wait for log readiness, measure first query.
    # Increased timeout to 25s for slow DNSCrypt certificate fetches.
    COLD_FILE="$BENCH_DIR/${SAFE}_cold.txt"
    : > "$COLD_FILE"
    COLD_FAIL=0

    for cs in $(seq 1 "$COLDSTART_SAMPLES"); do
        "$PROXY_BIN" -config "$CFG" > "$LOG.cold${cs}" 2>&1 &
        COLD_PID=$!
        ACTIVE_PIDS+=("$COLD_PID")

        if wait_proxy_log_ready "$COLD_PID" "$LOG.cold${cs}" 25; then
            RAND=$(openssl rand -hex 5)
            if COLD_Q=$(dig_query_time "$PORT" "${RAND}.cloudflare.com"); then
                echo "$COLD_Q" >> "$COLD_FILE"
            else
                COLD_FAIL=$((COLD_FAIL + 1))
            fi
        else
            COLD_FAIL=$((COLD_FAIL + 1))
        fi

        kill "$COLD_PID" 2>/dev/null || true
        wait "$COLD_PID" 2>/dev/null || true
    done

    COLDSTART=$(calc_median < "$COLD_FILE")

    # Persistent proxy for profiling
    "$PROXY_BIN" -config "$CFG" > "$LOG" 2>&1 &
    PID=$!
    ACTIVE_PIDS+=("$PID")

    if ! wait_proxy_log_ready "$PID" "$LOG" 15; then
        echo -e "${RED}FAILED (proxy did not become ready)${NC}"
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
        continue
    fi

    # Warmup phase to settle TLS and DNSCrypt sessions
    for warm_domain in google.com cloudflare.com github.com wikipedia.org; do
        for _ in $(seq 1 2); do
            dig_query_time "$PORT" "$warm_domain" >/dev/null 2>&1 || true
            [ "$IS_DOH" -eq 1 ] && doh_sleep
        done
    done
    for _ in $(seq 1 "$WARMUP_QUERIES"); do
        dig_query_time "$PORT" "google.com" >/dev/null 2>&1 || true
        [ "$IS_DOH" -eq 1 ] && doh_sleep
    done

    FAST_FILE="$BENCH_DIR/${SAFE}_fast.txt"
    FAST_DOM_REPORT="$BENCH_DIR/${SAFE}_fast_domains.txt"
    FAST_COUNTS=$(measure_domain_set "$PORT" "fast" "$FASTPATH_ROUNDS" "$FAST_FILE" "$FAST_DOM_REPORT" "${FASTPATH_DOMAINS[@]}")
    FAST_SUCCESS="${FAST_COUNTS%%|*}"
    FAST_TOTAL="${FAST_COUNTS##*|}"
    FAST_SUCCESS="${FAST_SUCCESS:-0}"
    FAST_TOTAL="${FAST_TOTAL:-0}"

    if [ $INTERRUPTED -eq 1 ]; then break; fi

    if [ "$FAST_SUCCESS" -eq 0 ]; then
        echo -e "${RED}FAILED (0 fast-path successful queries)${NC}"
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
        continue
    fi

    REC_FILE="$BENCH_DIR/${SAFE}_recursion.txt"
    REC_DOM_REPORT="$BENCH_DIR/${SAFE}_recursion_domains.txt"
    REC_COUNTS=$(measure_domain_set "$PORT" "recursion" "$RECURSION_ROUNDS" "$REC_FILE" "$REC_DOM_REPORT" "${RECURSION_BASE_DOMAINS[@]}")
    REC_SUCCESS="${REC_COUNTS%%|*}"
    REC_TOTAL="${REC_COUNTS##*|}"
    REC_SUCCESS="${REC_SUCCESS:-0}"
    REC_TOTAL="${REC_TOTAL:-0}"

    if [ $INTERRUPTED -eq 1 ]; then break; fi

    SEQ_BURST_FILE="$BENCH_DIR/${SAFE}_seq_burst.txt"
    PAR_BURST_FILE="$BENCH_DIR/${SAFE}_par_burst.txt"
    measure_seq_burst "$PORT" "$SEQ_BURST_FILE"
    measure_parallel_burst "$PORT" "$PAR_BURST_FILE" "$IS_DOH"

    if [ $INTERRUPTED -eq 1 ]; then break; fi

    FAST_LOSS=$(awk -v s="$FAST_SUCCESS" -v t="$FAST_TOTAL" 'BEGIN{if(t+0==0) print "100.00"; else printf "%.2f", ((t-s)/t)*100}')
    REC_LOSS=$(awk -v s="$REC_SUCCESS" -v t="$REC_TOTAL" 'BEGIN{if(t+0==0) print "100.00"; else printf "%.2f", ((t-s)/t)*100}')

    FAST_N=$(calc_count < "$FAST_FILE")
    FAST_MED=$(calc_median < "$FAST_FILE")
    FAST_AVG=$(calc_avg < "$FAST_FILE")
    FAST_TRIM=$(calc_trimmed_avg < "$FAST_FILE")
    FAST_P95=$(calc_percentile 0.95 < "$FAST_FILE")
    FAST_JIT=$(calc_stddev < "$FAST_FILE")

    if [ "$FAST_N" -ge 100 ]; then
        FAST_P99=$(calc_percentile 0.99 < "$FAST_FILE")
    else
        FAST_P99="NA"
    fi

    REC_N=$(calc_count < "$REC_FILE")
    REC_MED=$(calc_median < "$REC_FILE")
    REC_AVG=$(calc_avg < "$REC_FILE")
    REC_P95=$(calc_percentile 0.95 < "$REC_FILE")
    REC_JIT=$(calc_stddev < "$REC_FILE")

    SEQ_N=$(calc_count < "$SEQ_BURST_FILE")
    SEQ_AVG=$(calc_avg < "$SEQ_BURST_FILE")
    SEQ_P95=$(calc_percentile 0.95 < "$SEQ_BURST_FILE")
    SEQ_LOSS=$(awk -v s="$SEQ_N" -v t="$SEQ_BURST_QUERIES" 'BEGIN{printf "%.2f", ((t-s)/t)*100}')

    PAR_N=$(calc_count < "$PAR_BURST_FILE")
    PAR_AVG=$(calc_avg < "$PAR_BURST_FILE")
    PAR_P95=$(calc_percentile 0.95 < "$PAR_BURST_FILE")
    PAR_LOSS=$(awk -v s="$PAR_N" -v t="$PAR_BURST_QUERIES" 'BEGIN{printf "%.2f", ((t-s)/t)*100}')

    SCORE_PARTS=$(score_server "$FAST_MED" "$FAST_P95" "$FAST_JIT" "$FAST_LOSS" "$REC_MED" "$REC_P95" "$REC_LOSS" "$SEQ_P95" "$PAR_P95" "$COLDSTART")
    SCORE=$(printf "%s" "$SCORE_PARTS" | cut -d'|' -f1)
    SCORE_FAST=$(printf "%s" "$SCORE_PARTS" | cut -d'|' -f2)
    SCORE_REC=$(printf "%s" "$SCORE_PARTS" | cut -d'|' -f3)
    SCORE_BURST=$(printf "%s" "$SCORE_PARTS" | cut -d'|' -f4)
    SCORE_COLD=$(printf "%s" "$SCORE_PARTS" | cut -d'|' -f5)

    RELIABILITY="ok"
    # Safe awk checks preventing syntax errors on empty variables
    if awk -v fl="${FAST_LOSS:-0}" -v rl="${REC_LOSS:-0}" -v pl="${PAR_LOSS:-0}" 'BEGIN{exit !((fl > 1.0) || (rl > 5.0) || (pl > 5.0))}'; then
        RELIABILITY="watch"
    fi
    if awk -v fl="${FAST_LOSS:-0}" -v rl="${REC_LOSS:-0}" -v pl="${PAR_LOSS:-0}" 'BEGIN{exit !((fl > 3.0) || (rl > 10.0) || (pl > 10.0))}'; then
        RELIABILITY="weak"
    fi

    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$name" "$rtt" "$proto" "$GEO" "$RELIABILITY" \
        "$COLDSTART" "$COLD_FAIL" \
        "$FAST_N" "$FAST_MED" "$FAST_AVG" "$FAST_TRIM" "$FAST_P95" "$FAST_P99" "$FAST_JIT" "$FAST_LOSS" \
        "$REC_N" "$REC_MED" "$REC_AVG" "$REC_P95" "$REC_JIT" "$REC_LOSS" \
        "$SEQ_AVG" "$SEQ_P95" "$SEQ_LOSS" \
        "$PAR_AVG" "$PAR_P95" "$PAR_LOSS" \
        "$SCORE_FAST" "$SCORE_REC" "$SCORE_BURST" "$SCORE_COLD" "$SCORE" >> "$FINAL_TXT"

    sort -t'|' -k5 -nr "$FAST_DOM_REPORT" | head -n 4 | while IFS='|' read -r d n med avg p95; do
        printf "%s|fast|%s|%s|%s|%s|%s\n" "$name" "$d" "$n" "$med" "$avg" "$p95" >> "$DOMAIN_TAILS"
    done
    sort -t'|' -k5 -nr "$REC_DOM_REPORT" | head -n 4 | while IFS='|' read -r d n med avg p95; do
        printf "%s|recursion|%s|%s|%s|%s|%s\n" "$name" "$d" "$n" "$med" "$avg" "$p95" >> "$DOMAIN_TAILS"
    done

    printf "${GREEN}OK${NC} ${DIM}score=%s fast=%s rec=%s burst=%s rel=%s${NC}\n" \
        "$SCORE" "$SCORE_FAST" "$SCORE_REC" "$SCORE_BURST" "$RELIABILITY"

    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
done < "$BENCH_DIR/phase2_candidates.txt"

if [ $INTERRUPTED -eq 1 ]; then
    echo ""
    echo -e "${RED}Benchmark interrupted by user. Partial results saved.${NC}"
fi
echo ""

# ============================================================================
# REPORTS
# ============================================================================

echo -e "${YELLOW}[3/6]${NC} Main ranking — public resolver upstream score"
echo ""
echo -e "${WHITE}====================================================================================================================================${NC}"
printf "%-36.36s %-5s %-8s %-10s %-5s %-6s %-6s %-6s %-7s %-7s %-7s %-7s %-7s %-7s\n" \
    "SERVER" "RTT" "PROTO" "GEO" "REL" "F_MED" "F_P95" "F_LOSS" "R_MED" "R_P95" "P_P95" "COLD" "SCORE" "PARTS"
echo -e "${WHITE}====================================================================================================================================${NC}"

sort -t'|' -k32 -n "$FINAL_TXT" | while IFS='|' read -r \
    name rtt proto geo rel cold cold_fail \
    fast_n fast_med fast_avg fast_trim fast_p95 fast_p99 fast_jit fast_loss \
    rec_n rec_med rec_avg rec_p95 rec_jit rec_loss \
    seq_avg seq_p95 seq_loss par_avg par_p95 par_loss \
    score_fast score_rec score_burst score_cold score; do

    COLOR=$GREEN
    [ "$rel" = "watch" ] && COLOR=$YELLOW
    [ "$rel" = "weak" ] && COLOR=$RED

    printf "${COLOR}%-36.36s %-5s %-8s %-10s %-5s %-6s %-6s %-6s %-7s %-7s %-7s %-7s %-7s %s/%s/%s${NC}\n" \
        "$name" "${rtt}ms" "$proto" "$geo" "$rel" \
        "${fast_med}ms" "${fast_p95}ms" "${fast_loss}%" \
        "${rec_med}ms" "${rec_p95}ms" "${par_p95}ms" \
        "${cold}ms" "$score" "$score_fast" "$score_rec" "$score_burst"
done

echo ""
echo -e "${YELLOW}[4/6]${NC} Fast-path ranking only"
echo ""
printf "%-36.36s %-8s %-10s %-7s %-7s %-7s %-7s %-7s %-7s\n" \
    "SERVER" "PROTO" "GEO" "MED" "P95" "MAX" "JIT" "LOSS%" "TRIMAVG"

sort -t'|' -k28 -n "$FINAL_TXT" | head -n 10 | while IFS='|' read -r \
    name rtt proto geo rel cold cold_fail \
    fast_n fast_med fast_avg fast_trim fast_p95 fast_p99 fast_jit fast_loss \
    rec_n rec_med rec_avg rec_p95 rec_jit rec_loss \
    seq_avg seq_p95 seq_loss par_avg par_p95 par_loss \
    score_fast score_rec score_burst score_cold score; do

    printf "%-36.36s %-8s %-10s %-7s %-7s %-7s %-7s %-7s %-7s\n" \
        "$name" "$proto" "$geo" "${fast_med}ms" "${fast_p95}ms" "$fast_p99" "$fast_jit" "$fast_loss" "$fast_trim"
done

echo ""
echo -e "${YELLOW}[5/6]${NC} Top tail offenders per top candidates"
echo ""
echo -e "${DIM}      Helps identify which specific domains caused high P95 values.${NC}"
echo ""

while read -r top_name; do
    echo -e "  ${WHITE}${top_name}${NC}"
    awk -F'|' -v srv="$top_name" '$1 == srv {printf "      %-9s %-18s n=%-3s med=%-6sms avg=%-7sms p95=%sms\n", $2, $3, $4, $5, $6, $7}' "$DOMAIN_TAILS"
    echo ""
done < <(sort -t'|' -k32 -n "$FINAL_TXT" | head -n 6 | cut -d'|' -f1)

echo -e "${YELLOW}[6/6]${NC} Recommended dnscrypt-proxy config"
echo ""
echo "# For dnscrypt-proxy.toml"
echo "# Public resolver upstream set; sorted by score, excluding weak reliability."
echo "server_names = ["

awk -F'|' '$5 != "weak"' "$FINAL_TXT" |
    sort -t'|' -k32 -n |
    head -n 6 |
    while IFS='|' read -r name _; do
        echo "    '$name',"
    done

echo "]"
echo ""
echo "lb_strategy = 'wp2'"
echo "lb_estimator = true"
echo "cache = ${DNSCRYPT_CACHE}"
echo ""

# ============================================================================
# JSON EXPORT
# ============================================================================

OUTPUT_JSON="dns-benchmark-results-v8.json"
DOMAIN_JSON="dns-benchmark-domain-tails-v8.json"

jq -Rn '
[
  inputs |
  split("|") |
  {
    server: .[0],
    init_rtt_ms: .[1] | tonumber,
    proto: .[2],
    geo: .[3],
    reliability: .[4],
    coldstart_ms: .[5] | tonumber,
    coldstart_failures: .[6] | tonumber,
    fastpath: {
      n: .[7] | tonumber,
      median_ms: .[8] | tonumber,
      avg_ms: .[9] | tonumber,
      trimmed_avg_ms: .[10] | tonumber,
      p95_ms: .[11] | tonumber,
      p99_ms: (if .[12] == "NA" then null else .[12] | tonumber end),
      jitter: .[13] | tonumber,
      loss_pct: .[14] | tonumber
    },
    recursion: {
      n: .[15] | tonumber,
      median_ms: .[16] | tonumber,
      avg_ms: .[17] | tonumber,
      p95_ms: .[18] | tonumber,
      jitter: .[19] | tonumber,
      loss_pct: .[20] | tonumber
    },
    burst: {
      sequential_avg_ms: .[21] | tonumber,
      sequential_p95_ms: .[22] | tonumber,
      sequential_loss_pct: .[23] | tonumber,
      parallel_avg_ms: .[24] | tonumber,
      parallel_p95_ms: .[25] | tonumber,
      parallel_loss_pct: .[26] | tonumber
    },
    subscores: {
      fastpath: .[27] | tonumber,
      recursion: .[28] | tonumber,
      burst: .[29] | tonumber,
      coldstart: .[30] | tonumber
    },
    score: .[31] | tonumber
  }
] | sort_by(.score)
' < "$FINAL_TXT" > "$OUTPUT_JSON"

jq -Rn '
[
  inputs |
  split("|") |
  {
    server: .[0],
    profile: .[1],
    domain: .[2],
    n: .[3] | tonumber,
    median_ms: .[4] | tonumber,
    avg_ms: .[5] | tonumber,
    p95_ms: .[6] | tonumber
  }
]
' < "$DOMAIN_TAILS" > "$DOMAIN_JSON"

ELAPSED_MINUTES=$(( SECONDS / 60 ))
ELAPSED_SECONDS=$(( SECONDS % 60 ))

echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}Benchmark complete${NC}"
echo -e "${GREEN}============================================================================${NC}"
echo -e "  ${DIM}Total time:${NC} ${ELAPSED_MINUTES}m ${ELAPSED_SECONDS}s"
echo ""
echo -e "  ${DIM}Finished:${NC} $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  ${DIM}Results:${NC}   ./${OUTPUT_JSON}"
echo -e "  ${DIM}Domain tails:${NC} ./${DOMAIN_JSON}"
echo ""
echo -e "${CYAN}Score weights (Unbound Cache-Aware):${NC}"
echo "  Fast path = median*0.30 + p95*0.25 + jitter*0.30 + loss%^2*3"
echo "  Recursion = (median*0.10 + p95*0.12 + loss%*10) * 0.25"
echo "  Burst     = seq_p95*0.030 + parallel_p95*0.010"
echo "  Coldstart = min(cold_ms, 100)*0.01"
echo ""
echo -e "${CYAN}Note on DNSSEC Resolvers (e.g., Quad9):${NC}"
echo "  Strict DNSSEC resolvers naturally show higher P95 on Recursion tests"
echo "  due to NSEC validation on NXDOMAIN responses. This is a security feature."
echo "  The dns-ultra scoring accounts for this by heavily down-weighting Recursion,"
echo "  ensuring secure resolvers are not penalized in the final ranking."
echo ""
echo -e "${DIM}Tip: Prefer stable low-loss upstreams over tiny median wins.${NC}"
echo ""