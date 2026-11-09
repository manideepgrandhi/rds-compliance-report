#!/usr/bin/env bash
#
# rds_compliance_report.sh - one lightweight patch + backup compliance report for Aurora, RDS, Multi-AZ clusters,
# DocumentDB and Neptune. One script, two steps:
#   --save-data   one read-only scan per account (CloudShell) -> rds_compliance_<ACCOUNT>_<YYYYMMDD>.json
#                 calls: sts get-caller-identity, ec2 describe-regions (-A), and once per region rds describe-db-clusters,
#                 describe-db-instances, describe-pending-maintenance-actions, describe-db-cluster-snapshots,
#                 describe-db-snapshots, describe-db-engine-versions (per engine version), describe-db-major-engine-versions
#                 (per engine), backup list-backup-vaults / list-recovery-points-by-backup-vault; once per account
#                 rds describe-global-clusters
#   --merge       the report from those files, 0 AWS calls (CloudShell, Linux, macOS, Git Bash)
# Rules: none of its own. Patch status = rds-patch-compliance (versions behind > --max-behind is NON-COMPLIANT, a deprecated
# version is UNKNOWN); backup status = rds-backup-compliance lib/backup.jq (retention mismatch, excess backups and
# over-retention are warnings). The jq of both tools (collection and evaluation) is copied unchanged into lib/.
# Exit: 0 ok, 1 usage, 2 pre-check, 3 bad --merge input, 4 output error, 130 interrupted.

# shellcheck disable=SC2016,SC2034  # jq programs are single-quoted on purpose; KEEP_WORKDIR is read in the EXIT trap
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.2.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIBDIR="${RDS_CR_LIB:-$SCRIPT_DIR/lib}"
readonly DATA_SCHEMA="rds_compliance_data" DATA_SCHEMA_VERSION=2
readonly PATCH_SCHEMA="rds_patch_compliance_data" BACKUP_SCHEMA="rds_backup_compliance_data"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

PROFILES=(); REGIONS=(); ALL_REGIONS=0; MERGE_ARGS=()
OUTPUT_DIR=""; PREFIX="rds_compliance_report"; DISPLAY_TZ="Asia/Kolkata"; MAX_BEHIND=""; ORACLE_ANY=""
DAILY=7; DAILY_MAX_AGE_H=26; WEEKLY=auto; MONTHLY=12; YEARLY=0
WEEKLY_MIN_DAYS=25; WEEKLY_MAX_DAYS=40; MONTHLY_MIN_DAYS=300; MONTHLY_MAX_DAYS=400
WEEKLY_WEEKDAY=sat; MONTHLY_RULE=first-sun; TOLERANCE_DAYS=1; WEEKLY_WINDOW_DAYS=30; PARALLEL=4
DAILY_RETENTION_DAYS=""; WEEKLY_RETENTION_DAYS=30; MONTHLY_RETENTION_DAYS=365; RET_TOLERANCE_DAYS=1
LOG_FILE=""; CONFIG_FILE=""; AWS_TIMEOUT=30; MAX_ATTEMPTS=5
BG_PIDS=(); HAVE_WAIT_N=0; REG_I=0; REG_N=0; REG_T0=0
KEEP_WORKDIR=0; DRY_RUN=0; VERBOSE=0; SAVE_DATA=0; SAVE_DATA_FILE=""; MERGE=0
EXC_FILE=""; EXC_JSON="null"; EXC_PATH=""; EXC_ARGS=()   # v1.2.0 compliance exceptions (--merge only)
WORK=""; NOW=0; STAMP=""; AWS_CALLS=0; AWS_FAILS=0; TZ_OFFSET=0; TZ_LABEL=UTC; CFG=""
declare -a WRITTEN=() DATA_FILES=()

_log() { local l; l="$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}"; printf '%s\n' "$l" >&2
         if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$l" >>"$LOG_FILE" 2>/dev/null || true; fi; }
log_info() { _log INFO "$@"; }; log_warn() { _log WARN "$@"; }; log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local c="$1"; shift; log_error "$@"; exit "$c"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME $SCRIPT_VERSION - patch + backup compliance in one offline report

1. Collect, once per account (CloudShell, read-only) -> rds_compliance_<ACCOUNT>_<YYYYMMDD>.json:
  $SCRIPT_NAME --save-data [FILE] [-P PROFILE[,..]] [-r REGION[,..] | -A] [--parallel N] [-o DIR] [-v]

2. Build the report from those files (0 AWS calls; CloudShell, Linux, macOS, Git Bash):
  $SCRIPT_NAME --merge FILE|DIR [FILE|DIR ...] -o DIR [options]
    inputs: rds_compliance_*.json. Per account the newest collection wins.

Example: $SCRIPT_NAME --save-data -A   then   $SCRIPT_NAME --merge . -o report

Options
  -P, --profile P[,P]     AWS CLI profile(s) (collect)          -r, --region R[,R]   regions (collect)
  -A, --all-regions       every enabled region (collect)        --parallel N         regions at a time (default 4)
  -o, --output-dir DIR    output folder                         -l, --log-file F     also log to F
  --max-behind N          patch: NON-COMPLIANT above N minor versions behind (default: as saved, 2)
  --oracle-any-patch-line patch: Oracle counts any newer patch line
  --daily N --daily-max-age H --weekly N|auto --monthly N --yearly N --weekly-days MIN-MAX --monthly-days MIN-MAX
  --weekly-weekday DAY --monthly-rule first-DAY --tolerance-days N --weekly-window-days N
  --daily-retention-days N --weekly-retention-days N --monthly-retention-days N --retention-tolerance-days N
                          backup thresholds, same meaning and defaults as rds-backup-compliance
  --exceptions FILE       compliance exceptions, applied at --merge (default: compliance_exceptions.conf next to the
                          script when present, else off). Lines: account_id | identifier | scope | expires | reason
                          scope patch, backup or patch,backup; expires YYYY-MM-DD (mandatory). See the .example file
  --prefix P              output file prefix (default rds_compliance_report)
  --tz ZONE               second time zone (default Asia/Kolkata = IST)
  --config FILE           key=value file with any long option above (see conf.example)
  --aws-timeout S --max-attempts N --dry-run --keep-workdir -v/--verbose -V/--version -h/--help
Output (merge): <prefix>_<account|N_accounts>_<UTC stamp>.html / .txt / _servers.csv / _accounts.csv / _regions.csv / _engines.csv
Exit: 0 ok, 1 usage, 2 pre-check, 3 bad --merge input, 4 output error, 130 interrupted
USAGE
}

add_list() { local -n _a="$1"; local _i; local -a _p; IFS=',' read -r -a _p <<<"$2"
             for _i in "${_p[@]}"; do _i="${_i//[[:space:]]/}"; [[ -n "$_i" ]] && _a+=("$_i"); done; return 0; }
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
dow_ok() { [[ "${2,,}" =~ ^(sun|mon|tue|wed|thu|fri|sat)$ ]] || die 1 "$1 must be sun, mon, tue, wed, thu, fri or sat (got '$2')"; }
dow_num() { case "$1" in sun) echo 0 ;; mon) echo 1 ;; tue) echo 2 ;; wed) echo 3 ;; thu) echo 4 ;; fri) echo 5 ;; *) echo 6 ;; esac; }
int_ok() { [[ "$2" =~ ^[0-9]+$ ]] || die 1 "$1 must be a whole number (got '$2')"; }
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs . | tr -d '\r'; else printf '[]'; fi; }
jqv() { jq "$@" | tr -d '\r'; }       # jq.exe on Windows writes CRLF: strip for values and files

set_opt() {   # set_opt key value  (shared by CLI and --config)
    local k="$1" v="$2"
    case "$k" in
        profile) add_list PROFILES "$v" ;; region) add_list REGIONS "$v" ;; all-regions|all_regions) is_true "$v" && ALL_REGIONS=1 ;;
        max-behind|max_behind) int_ok --max-behind "$v"; MAX_BEHIND="$v" ;;
        oracle-any-patch-line|oracle_any_patch_line) if is_true "$v"; then ORACLE_ANY=true; fi ;;
        daily) int_ok --daily "$v"; DAILY="$v" ;; daily-max-age|daily_max_age) int_ok --daily-max-age "$v"; DAILY_MAX_AGE_H="$v" ;;
        weekly) [[ "$v" == auto ]] || int_ok --weekly "$v"; WEEKLY="$v" ;; monthly) int_ok --monthly "$v"; MONTHLY="$v" ;; yearly) int_ok --yearly "$v"; YEARLY="$v" ;;
        weekly-days|weekly_days) [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]] || die 1 "--weekly-days must be MIN-MAX (got '$v')"
            WEEKLY_MIN_DAYS="${BASH_REMATCH[1]}"; WEEKLY_MAX_DAYS="${BASH_REMATCH[2]}" ;;
        monthly-days|monthly_days) [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]] || die 1 "--monthly-days must be MIN-MAX (got '$v')"
            MONTHLY_MIN_DAYS="${BASH_REMATCH[1]}"; MONTHLY_MAX_DAYS="${BASH_REMATCH[2]}" ;;
        daily-retention-days|daily_retention_days) int_ok --daily-retention-days "$v"; DAILY_RETENTION_DAYS="$v" ;;
        weekly-retention-days|weekly_retention_days) int_ok --weekly-retention-days "$v"; WEEKLY_RETENTION_DAYS="$v" ;;
        monthly-retention-days|monthly_retention_days) int_ok --monthly-retention-days "$v"; MONTHLY_RETENTION_DAYS="$v" ;;
        retention-tolerance-days|retention_tolerance_days) int_ok --retention-tolerance-days "$v"; RET_TOLERANCE_DAYS="$v" ;;
        weekly-weekday|weekly_weekday) dow_ok --weekly-weekday "$v"; WEEKLY_WEEKDAY="${v,,}" ;;
        monthly-rule|monthly_rule) [[ "${v,,}" =~ ^first-(sun|mon|tue|wed|thu|fri|sat)$ ]] || die 1 "--monthly-rule must be first-DAY, e.g. first-sun (got '$v')"; MONTHLY_RULE="${v,,}" ;;
        tolerance-days|tolerance_days) int_ok --tolerance-days "$v"; TOLERANCE_DAYS="$v" ;;
        weekly-window-days|weekly_window_days) int_ok --weekly-window-days "$v"; WEEKLY_WINDOW_DAYS="$v" ;;
        parallel) int_ok --parallel "$v"; (( v >= 1 )) || die 1 "--parallel must be 1 or more"; PARALLEL="$v" ;;
        output-dir|output_dir) OUTPUT_DIR="$v" ;; log-file|log_file) LOG_FILE="$v" ;;
        prefix) [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix may only use letters, digits, . _ - (got '$v')"; PREFIX="$v" ;;
        tz) DISPLAY_TZ="$v" ;; exceptions) EXC_FILE="$v" ;;
        aws-timeout|aws_timeout) int_ok --aws-timeout "$v"; AWS_TIMEOUT="$v" ;; max-attempts|max_attempts) int_ok --max-attempts "$v"; MAX_ATTEMPTS="$v" ;;
        verbose) is_true "$v" && VERBOSE=1 ;;
        *) return 1 ;;
    esac
    return 0
}

load_config() {
    local f="$1" line n=0
    [[ -r "$f" ]] || die 1 "Config file not readable: $f"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_-]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] || die 1 "Config $f:$n: expected key=value"
        set_opt "${BASH_REMATCH[1],,}" "${BASH_REMATCH[2]:-}" || die 1 "Config $f:$n: unknown key '${BASH_REMATCH[1]}'"
    done <"$f"
}

parse_args() {
    local a; for ((a = 1; a <= $#; a++)); do if [[ "${!a}" == --config ]]; then local b=$((a + 1)); [[ $b -le $# ]] || die 1 "--config needs a file"; CONFIG_FILE="${!b}"; fi; done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    while (( $# )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            -P|--profile) need_arg "$1" $#; add_list PROFILES "$2"; shift ;;
            -r|--region) need_arg "$1" $#; add_list REGIONS "$2"; shift ;;
            -A|--all-regions) ALL_REGIONS=1 ;;
            -o|--output-dir) need_arg "$1" $#; OUTPUT_DIR="$2"; shift ;;
            -l|--log-file) need_arg "$1" $#; LOG_FILE="$2"; shift ;;
            --config) shift ;;
            --oracle-any-patch-line) ORACLE_ANY=true ;;
            --keep-workdir) KEEP_WORKDIR=1 ;; --dry-run) DRY_RUN=1 ;; -v|--verbose) VERBOSE=1 ;;
            --save-data) SAVE_DATA=1; if [[ $# -ge 2 && "$2" != -* ]]; then SAVE_DATA_FILE="$2"; shift; fi ;;
            --merge) MERGE=1; while [[ $# -ge 2 && "$2" != -* ]]; do MERGE_ARGS+=("$2"); shift; done ;;
            --max-behind|--daily|--daily-max-age|--weekly|--monthly|--yearly|--weekly-days|--monthly-days|--daily-retention-days|--weekly-retention-days|--monthly-retention-days|--retention-tolerance-days|--weekly-weekday|--monthly-rule|--tolerance-days|--parallel|--weekly-window-days|--prefix|--tz|--exceptions|--aws-timeout|--max-attempts)
                need_arg "$1" $#; set_opt "${1#--}" "$2"; shift ;;
            --*=*) local k="${1%%=*}"; set_opt "${k#--}" "${1#*=}" || die 1 "Unknown option: $1" ;;
            *) die 1 "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    (( WEEKLY_MIN_DAYS <= WEEKLY_MAX_DAYS && WEEKLY_MAX_DAYS < MONTHLY_MIN_DAYS && MONTHLY_MIN_DAYS <= MONTHLY_MAX_DAYS )) \
        || die 1 "Need weekly-days MIN <= MAX < monthly-days MIN <= MAX (got weekly $WEEKLY_MIN_DAYS-$WEEKLY_MAX_DAYS, monthly $MONTHLY_MIN_DAYS-$MONTHLY_MAX_DAYS)"
    (( MERGE || SAVE_DATA )) || die 1 "Choose --save-data (collect) or --merge FILE|DIR ... (build the report); see --help"
    if (( MERGE )); then
        (( ${#MERGE_ARGS[@]} )) || die 1 "--merge needs at least one FILE or DIR"
        (( ${#PROFILES[@]} || ${#REGIONS[@]} || ALL_REGIONS )) && die 1 "--merge works offline: do not combine it with -P / -r / -A"
        (( SAVE_DATA )) && die 1 "--save-data cannot be combined with --merge"
        [[ -n "$OUTPUT_DIR" ]] || die 1 "--merge needs -o DIR"
    fi
    (( ALL_REGIONS && ${#REGIONS[@]} > 1 )) && die 1 "Use either -A or -r, not both"
    return 0
}

tz_setup() {   # offset seconds + label of the second time zone (Git Bash date may lack zoneinfo: fallback for IST)
    local z; z="$(TZ="$DISPLAY_TZ" date +%z 2>/dev/null || echo +0000)"
    [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || z="+0000"
    [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]]
    TZ_OFFSET=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 )); [[ "${BASH_REMATCH[1]}" == - ]] && TZ_OFFSET=$(( -TZ_OFFSET ))
    case "$DISPLAY_TZ" in Asia/Kolkata|Asia/Calcutta|IST) TZ_LABEL=IST; TZ_OFFSET=19800 ;;
        *) TZ_LABEL="$(TZ="$DISPLAY_TZ" date +%Z 2>/dev/null || echo "$DISPLAY_TZ")"; [[ "$TZ_LABEL" =~ ^[+-] ]] && TZ_LABEL="UTC$TZ_LABEL" ;; esac
    return 0
}

cfg_json() {   # identical to rds-backup-compliance v1.5.1 (manual-snapshot audit and price are not used here)
    local w="$WEEKLY"; [[ "$w" == auto ]] && w='"auto"'
    jq -cn --argjson d "$DAILY" --argjson h "$DAILY_MAX_AGE_H" --argjson w "$w" --argjson m "$MONTHLY" --argjson y "$YEARLY" \
        --argjson wmin "$WEEKLY_MIN_DAYS" --argjson wmax "$WEEKLY_MAX_DAYS" --argjson mmin "$MONTHLY_MIN_DAYS" --argjson mmax "$MONTHLY_MAX_DAYS" \
        --argjson wd "$(dow_num "$WEEKLY_WEEKDAY")" --argjson md "$(dow_num "${MONTHLY_RULE#first-}")" --argjson tol "$TOLERANCE_DAYS" --argjson ww "$WEEKLY_WINDOW_DAYS" \
        --argjson dr "${DAILY_RETENTION_DAYS:-$DAILY}" --argjson wr "$WEEKLY_RETENTION_DAYS" --argjson mr "$MONTHLY_RETENTION_DAYS" --argjson rt "$RET_TOLERANCE_DAYS" \
        --argjson off "$TZ_OFFSET" --arg lab "$TZ_LABEL" \
        '{manual_older_than: null, snapshot_price_per_gb: 0.021, daily: $d, daily_max_age_h: $h, weekly: $w, monthly: $m, yearly: $y, weekly_min_days: $wmin, weekly_max_days: $wmax,
          monthly_min_days: $mmin, monthly_max_days: $mmax, weekly_weekday: $wd, monthly_weekday: $md, tolerance_days: $tol, weekly_window_days: $ww,
          daily_retention_days: $dr, weekly_retention_days: $wr, monthly_retention_days: $mr, ret_tolerance_days: $rt,
          tz_offset: $off, tz_label: $lab}' | tr -d '\r'
}
when() { jqv -rn --argjson e "$1" --argjson o "$TZ_OFFSET" --arg l "$TZ_LABEL" \
         '"\($e | todate | sub("T"; " ") | sub("Z"; " UTC")) / \($e + $o | todate | sub("T"; " ") | sub("Z"; " " + $l))"'; }

# ---------------------------------------------------------------------------- AWS (read-only, collect only)
awsc() {   # awsc <out-file> <profile> <region> <service> <operation> [args...]; stderr -> <out-file>.err
    local out="$1" prof="$2" reg="$3"; shift 3
    local -a cmd=(aws "$@" --output json --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$reg" ]] && cmd+=(--region "$reg"); [[ -n "$prof" ]] && cmd+=(--profile "$prof")
    if (( DRY_RUN )); then printf 'DRY-RUN: %s\n' "${cmd[*]}"; echo '{}' >"$out"; return 0; fi
    AWS_CALLS=$((AWS_CALLS + 1)); log_debug "${cmd[*]}"
    if AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE=standard AWS_PAGER="" "${cmd[@]}" >"$out" 2>"$out.err"; then return 0; fi
    AWS_FAILS=$((AWS_FAILS + 1)); return 1
}
err_of() { tr -d '\r' <"$1.err" 2>/dev/null | grep -v '^[[:space:]]*$' | sed -E 's/^aws: \[ERROR\]: //; s/An error occurred //' | head -1 | cut -c1-200 || true; }

svc_of() { case "$1" in docdb) echo docdb ;; neptune) echo neptune ;; *) echo rds ;; esac; }
perr() {   # perr <dir> <account> <profile> <region> <call> <message>: an error entry of the patch data (rds-patch-compliance format)
    jqv -cn --arg a "$2" --arg p "${3:-default}" --arg r "$4" --arg c "$5" --arg m "$6" '{account: $a, profile: $p, region: $r, call: $c, message: $m}' >>"$1/perr.jsonl"
}
collect_versions() {   # as rds-patch-compliance: one describe-db-engine-versions per (engine, version), one lifecycle call per rds engine
    local prof="$1" reg="$2" d="$3" engine ver svc key cache lc m; local -a evs=() lcs=()
    mkdir -p "$d/ev"
    while IFS=$'\t' read -r engine ver; do
        [[ -n "$engine" ]] || continue
        svc="$(svc_of "$engine")"; key="$(printf '%s_%s' "$engine" "$ver" | tr -c 'A-Za-z0-9._-' '_')"; cache="$d/ev/ev_$key.json"
        if [[ ! -s "$cache" ]]; then
            if awsc "$cache.raw" "$prof" "$reg" "$svc" describe-db-engine-versions --engine "$engine" --engine-version "$ver"; then
                jqv -c --arg e "$engine" --arg v "$ver" '[.DBEngineVersions[]? | select(.Engine == $e and .EngineVersion == $v)][0] as $x
                    | {key: ($e + "|" + $v), value: {ok: true, error: null, returned: ($x != null),
                       major: ($x.MajorEngineVersion // (($x.DBParameterGroupFamily // "") | sub("^[A-Za-z-]+"; "") | if . == "" then null else . end)),
                       targets: [($x.ValidUpgradeTarget // [])[] | {Engine, EngineVersion, IsMajorVersionUpgrade, AutoUpgrade}]}}' "$cache.raw" >"$cache"
                [[ "$(jqv -r '.value.returned' "$cache")" == true ]] || log_warn "$reg: $engine $ver is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN"
            else
                AWS_FAILS=$((AWS_FAILS - 1)); m="$(err_of "$cache.raw")"   # supplementary lookup: a warning, not a failure (as the patch tool)
                log_warn "$reg: engine-version lookup for $engine $ver failed ($m); its servers are UNKNOWN"
                jqv -cn --arg e "$engine" --arg v "$ver" --arg m "$m" '{key: ($e + "|" + $v), value: {ok: false, error: $m, returned: false, major: null, targets: []}}' >"$cache"
            fi
        fi
        evs+=("$cache"); [[ "$svc" == rds ]] || continue
        lc="$d/ev/lc_$engine.json"
        if [[ ! -s "$lc" && ! -e "$WORK/lc_unsupported" ]]; then
            if awsc "$lc.raw" "$prof" "$reg" rds describe-db-major-engine-versions --engine "$engine"; then
                jqv -c --arg e "$engine" '{key: $e, value: {majors: [.DBMajorEngineVersions[]? | {MajorEngineVersion, SupportedEngineLifecycles}]}}' "$lc.raw" >"$lc"
            else
                AWS_FAILS=$((AWS_FAILS - 1)); m="$(err_of "$lc.raw")"
                if [[ "$m" == *"nvalid choice"* ]]; then : >"$WORK/lc_unsupported"; log_warn "This AWS CLI has no 'rds describe-db-major-engine-versions' (upgrade the CLI); support end dates show 'unknown'"
                else log_warn "$reg: lifecycle lookup for $engine failed ($m); support end dates show 'unknown'"; fi
                printf '{}' >"$lc"
            fi
        fi
        [[ -s "$lc" ]] && lcs+=("$lc")
    done < <(jqv -r -s '[.[0][], .[1][]] | map(select((.Engine // "") != "" and (.EngineVersion // "") != "") | [.Engine, .EngineVersion]) | unique[]
                       | select(.[0] | test("^(aurora-postgresql|aurora-mysql|postgres|mysql|mariadb|sqlserver-(ee|se|ex|web)|oracle-(ee|se2|ee-cdb|se2-cdb)|docdb|neptune)$")) | @tsv' \
                 "$d/instances.json" "$d/clusters.json")
    if (( ${#evs[@]} )); then jqv -cs 'from_entries' -- "${evs[@]}" >"$d/ev.json"; else printf '{}' >"$d/ev.json"; fi
    if (( ${#lcs[@]} )); then jqv -cs 'map(select(has("key"))) | from_entries' -- "${lcs[@]}" >"$d/lc.json"; else printf '{}' >"$d/lc.json"; fi
}
patch_rows() {   # rds-patch-compliance lib/compliance.jq, mode rows (the status is recomputed at merge with --max-behind)
    TZ="$DISPLAY_TZ" jq -n --arg mode rows --argjson now "$NOW" --argjson max_behind "${MAX_BEHIND:-2}" --argjson warn_days 180 --argjson top_n 10 \
        --argjson nc_only false --argjson oracle_any "${ORACLE_ANY:-false}" --argjson tagcols '[]' --argjson f '{"engines":[],"identifiers":[]}' \
        --arg profile "${1:-default}" --arg account "$2" --arg region "$3" --slurpfile clusters "$4/clusters.json" --slurpfile instances "$4/instances.json" \
        --slurpfile pma "$4/pma.json" --slurpfile ev "$4/ev.json" --slurpfile lc "$4/lc.json" -f "$LIBDIR/patch_compliance.jq" | tr -d '\r'
}

# One scan per region, every call once: the patch and the backup data share describe-db-clusters / describe-db-instances.
# With -A these two full calls are also the region discovery: a region with neither is empty and gets no further call.
scan_region() {   # scan_region <profile> <account> <region> <dir> -> raw files, rows.json (patch), scan.json
    local prof="$1" acct="$2" reg="$3" d="$4" e n nc ni; local -a errs=()
    local c0=$AWS_CALLS f0=$AWS_FAILS csnap_ok=true isnap_ok=true backup_ok=true cl_ok=1 in_ok=1
    : >"$d/perr.jsonl"
    for e in c i cs is; do echo '{}' >"$d/$e.json"; done; echo '[]' >"$d/rp.json"; echo '[]' >"$d/pma.json"; echo '[]' >"$d/rows.json"
    awsc "$d/c.json" "$prof" "$reg" rds describe-db-clusters || { cl_ok=0; e="$(err_of "$d/c.json")"; errs+=("describe-db-clusters: $e"); perr "$d" "$acct" "$prof" "$reg" "rds describe-db-clusters" "$e"; echo '{}' >"$d/c.json"; }
    awsc "$d/i.json" "$prof" "$reg" rds describe-db-instances || { in_ok=0; e="$(err_of "$d/i.json")"; errs+=("describe-db-instances: $e"); (( cl_ok )) && perr "$d" "$acct" "$prof" "$reg" "rds describe-db-instances" "$e"; echo '{}' >"$d/i.json"; }
    jqv -c '.DBClusters // []' "$d/c.json" >"$d/clusters.json"; jqv -c '.DBInstances // []' "$d/i.json" >"$d/instances.json"
    nc="$(jqv length "$d/clusters.json")"; ni="$(jqv length "$d/instances.json")"; n=$((nc + ni))
    (( DRY_RUN )) && n=1
    if (( n > 0 )); then
        if (( cl_ok && in_ok )); then
            if awsc "$d/pma.raw" "$prof" "$reg" rds describe-pending-maintenance-actions; then jqv -c '.PendingMaintenanceActions // []' "$d/pma.raw" >"$d/pma.json"
            else perr "$d" "$acct" "$prof" "$reg" "rds describe-pending-maintenance-actions" "$(err_of "$d/pma.raw") (pending_actions shown as 0)"; echo '[]' >"$d/pma.json"; fi
        fi
        awsc "$d/cs.json" "$prof" "$reg" rds describe-db-cluster-snapshots --include-shared || { csnap_ok=false; errs+=("describe-db-cluster-snapshots: $(err_of "$d/cs.json")"); echo '{}' >"$d/cs.json"; }
        awsc "$d/is.json" "$prof" "$reg" rds describe-db-snapshots --include-shared || { isnap_ok=false; errs+=("describe-db-snapshots: $(err_of "$d/is.json")"); echo '{}' >"$d/is.json"; }
        if awsc "$d/v.json" "$prof" "$reg" backup list-backup-vaults; then
            local v k=0
            while IFS= read -r v; do
                [[ -n "$v" ]] || continue; k=$((k + 1))
                awsc "$d/rp$k.json" "$prof" "$reg" backup list-recovery-points-by-backup-vault --backup-vault-name "$v" \
                    || { backup_ok=false; errs+=("list-recovery-points-by-backup-vault $v: $(err_of "$d/rp$k.json")"); echo '{}' >"$d/rp$k.json"; }
            done < <(jqv -r '.BackupVaultList[]?.BackupVaultName' "$d/v.json")
            if (( k )); then jqv -s '[ .[].RecoveryPoints[]? | select(.ResourceType == "Aurora" or .ResourceType == "RDS" or (.ResourceArn // "" | test(":rds:"))) ]' "$d"/rp[0-9]*.json >"$d/rp.json"; fi
        else backup_ok=false; errs+=("list-backup-vaults: $(err_of "$d/v.json")"); fi
        (( cl_ok && in_ok )) && collect_versions "$prof" "$reg" "$d"
    fi
    if (( cl_ok && in_ok && ! DRY_RUN )) && (( n > 0 )); then patch_rows "$prof" "$acct" "$reg" "$d" >"$d/rows.json"; fi
    for e in "${errs[@]}"; do log_warn "$acct $reg: $e"; done
    local st=databases; (( n == 0 )) && st=empty; (( cl_ok && in_ok )) || st=error
    jqv -n --arg s "$st" --argjson e "$(json_array "${errs[@]}")" --argjson cs "$csnap_ok" --argjson is "$isnap_ok" --argjson bo "$backup_ok" \
        --argjson nc "$nc" --argjson ni "$ni" --slurpfile c "$d/clusters.json" --slurpfile rp "$d/rp.json" --slurpfile x "$d/cs.json" --slurpfile y "$d/is.json" \
        '{status: $s, errors: $e, csnap_ok: $cs, isnap_ok: $is, backup_ok: $bo, clusters: $nc, instances: $ni,
          rds_clusters: ([$c[0][] | select(.Engine // "" | test("^(docdb|neptune)") | not)] | length),
          snapshots: (([$x[0].DBClusterSnapshots[]?] | length) + ([$y[0].DBSnapshots[]?] | length)), recovery_points: ($rp[0] | length)}' >"$d/scan.json"
    region_progress "$reg" "$d/scan.json"
    echo "$((AWS_CALLS - c0)) $((AWS_FAILS - f0))" >"$d/stats"
}

region_job() {   # background job: scan_region in a subshell; <dir>/rc marks a normal finish
    local d="$4"
    trap - EXIT INT TERM; set +e
    ( set -e; shopt -s inherit_errexit 2>/dev/null || true; scan_region "$@" ); echo $? >"$d/rc"
}

region_failed() {   # placeholder result so the other regions still report
    for f in clusters instances rows rp pma; do echo '[]' >"$3/$f.json"; done; for f in c i cs is; do echo '{}' >"$3/$f.json"; done
    perr "$3" "$1" "$5" "$2" "region scan" "region scan failed: $4"
    jqv -n --arg e "region scan failed: $4" '{status: "error", errors: [$e], csnap_ok: false, isnap_ok: false, backup_ok: false, clusters: 0, instances: 0, rds_clusters: 0, snapshots: 0, recovery_points: 0}' >"$3/scan.json"
}

plural() { if (( $1 == 1 )); then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }
region_progress() {   # one line per region with databases (every region with -v); errors always shown
    local reg="$1" s="$2" line nc ni sn rp ne secs=$(( SECONDS - ${REG_T0:-$SECONDS} ))
    read -r nc ni sn rp ne < <(jqv -r '"\(.clusters) \(.instances) \(.snapshots) \(.recovery_points) \(.errors | length)"' "$s") || true
    if [[ -z "$ne" ]]; then line="failed: unreadable AWS output"
    elif (( nc + ni == 0 )); then (( ne == 0 && VERBOSE != 1 )) && return 0; line="(empty)"; (( ne )) && line="(no data)"
    else line="$(plural "$nc" cluster), $(plural "$ni" instance), $(plural "$sn" snapshot), $(plural "$rp" "recovery point") (${secs}s)"; fi
    (( ${ne:-0} )) && line+=" - ERROR: $(jqv -r '.errors | join("; ")' "$s")"
    log_info "[$REG_I/$REG_N] $reg: $line"
}

region_summary() {   # "5 regions scanned, 18 clusters, 37 instances, 2 empty: a, b" (+ failed regions)
    log_info "$1: $(jqv -rs --argjson n "$2" '(map(select(.status == "empty") | .region)) as $e | (map(select(.status == "error") | .region)) as $f
        | (map(.clusters) | add) as $c | (map(.instances) | add) as $i
        | "\(length) region\(if length == 1 then "" else "s" end) scanned, \($c) cluster\(if $c == 1 then "" else "s" end), \($i) instance\(if $i == 1 then "" else "s" end), \($e | length) empty\(if ($e | length) > 0 then ": " + ($e | join(", ")) else "" end)"
          + (if ($f | length) > 0 then "; \($f | length) failed: \($f | join(", "))" else "" end)' "$WORK/$1"/*/rs.json)"
}

build_region() {   # build_region <account> <region> <dir> <globals-file> <global_ok> [extra error]: backup + DocumentDB/Neptune results, 0 AWS calls
    local a="$1" r="$2" d="$3" gf="$4" gok="$5" st n no; local s="$d/scan.json"
    if [[ -n "${6:-}" ]]; then jqv --arg e "$6" '.errors += [$e]' "$s" >"$s.t" && mv "$s.t" "$s"; fi
    local cs is bo; read -r cs is bo < <(jqv -r '"\(.csnap_ok) \(.isnap_ok) \(.backup_ok)"' "$s")
    # rds-backup-compliance lib/collect.jq (skips DocumentDB / Neptune)
    jqv -n --arg acct "$a" --arg region "$r" --slurpfile clusters "$d/c.json" --slurpfile instances "$d/i.json" \
        --slurpfile csnaps "$d/cs.json" --slurpfile isnaps "$d/is.json" --slurpfile rps "$d/rp.json" --slurpfile globals "$gf" \
        --argjson csnap_ok "$cs" --argjson isnap_ok "$is" --argjson backup_ok "$bo" --argjson global_ok "$gok" -f "$LIBDIR/backup_collect.jq" >"$d/coll.json"
    jqv '.resources' "$d/coll.json" >"$d/resources.json"; jqv '.orphans' "$d/coll.json" >"$d/orphans.json"
    n="$(jqv length "$d/resources.json")"; no="$(jqv length "$d/orphans.json")"
    if [[ "$(jqv '.errors | length' "$s")" != 0 ]]; then st=error; elif (( n > 0 )); then st="with databases"; elif (( no > 0 )); then st="snapshots only"; else st=empty; fi
    jqv -n --arg a "$a" --arg r "$r" --arg s "$st" --argjson n "$n" --slurpfile x "$s" --slurpfile c "$d/coll.json" \
        '{account: $a, region: $r, status: $s, resources: $n, errors: $x[0].errors, snapshot_scan: ($x[0].csnap_ok and $x[0].isnap_ok), existing: $c[0].existing}' >"$d/region.json"
    # DocumentDB / Neptune (v1.0 lib/collect_docdb.jq)
    jqv -n --arg acct "$a" --arg region "$r" --slurpfile clusters "$d/c.json" --slurpfile csnaps "$d/cs.json" --slurpfile rps "$d/rp.json" \
        --argjson csnap_ok "$cs" --argjson backup_ok "$bo" -f "$LIBDIR/collect_docdb.jq" >"$d/dres.json"
    n="$(jqv length "$d/dres.json")"
    if [[ "$(jqv '.errors | length' "$s")" != 0 ]]; then st=error; elif (( n > 0 )); then st="with databases"; else st=empty; fi
    jqv -n --arg a "$a" --arg r "$r" --arg s "$st" --argjson n "$n" --slurpfile x "$s" \
        '{account: $a, region: $r, status: $s, resources: $n, errors: $x[0].errors, snapshot_scan: $x[0].csnap_ok, existing: null}' >"$d/dregion.json"
    jqv -n --arg a "$a" --arg r "$r" --slurpfile x "$s" '{account: $a, region: $r, status: $x[0].status, servers: ($x[0].clusters + $x[0].instances), instances: $x[0].instances, clusters: $x[0].clusters}' >"$d/rs.json"
}

scan_profile() {   # scan_profile <profile> -> $WORK/data_<account>.json
    local prof="$1" acct reg d i=0 st idf="$WORK/id_${1:-default}.json" c_acct=$AWS_CALLS f_acct=$AWS_FAILS; local -a regs=()
    if (( DRY_RUN )); then acct="ACCOUNT"; awsc "$idf" "$prof" "" sts get-caller-identity
    else
        awsc "$idf" "$prof" "" sts get-caller-identity || { log_error "profile '${prof:-default}': no valid credentials ($(err_of "$idf"))"; return 1; }
        acct="$(jqv -r '.Account // empty' "$idf")"; [[ -n "$acct" ]] || { log_error "profile '${prof:-default}': no account id"; return 1; }
    fi
    if (( ALL_REGIONS )); then
        if (( DRY_RUN )); then awsc "$WORK/regs.json" "$prof" "${REGIONS[0]:-us-east-1}" ec2 describe-regions; regs=("<each-enabled-region>")
        else
            awsc "$WORK/regs.json" "$prof" "${REGIONS[0]:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}" ec2 describe-regions --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
                || { log_error "$acct: ec2 describe-regions failed ($(err_of "$WORK/regs.json"))"; return 1; }
            mapfile -t regs < <(jqv -r '.Regions[].RegionName' "$WORK/regs.json" | sort)
        fi
    elif (( ${#REGIONS[@]} )); then regs=("${REGIONS[@]}")
    else
        reg="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
        [[ -n "$reg" ]] || reg="$(aws configure get region ${prof:+--profile "$prof"} 2>/dev/null | tr -d '\r' || true)"
        [[ -n "$reg" ]] || { log_error "No region: use -r REGION or -A"; return 1; }
        regs=("$reg")
    fi
    local n=${#regs[@]} par=$PARALLEL running=0
    (( DRY_RUN || n < 2 )) && par=1
    log_info "$acct (${prof:-default}): scanning $(plural "$n" region) for patch + backup data, up to $par at a time"
    for reg in "${regs[@]}"; do
        i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"; mkdir -p "$d"; REG_I=$i; REG_N=$n; REG_T0=$SECONDS
        if (( par == 1 )); then scan_region "$prof" "$acct" "$reg" "$d"; echo 0 >"$d/rc"; continue; fi
        if (( running >= par )); then
            if (( HAVE_WAIT_N )); then wait -n || true; running=$((running - 1)); else wait || true; running=0; fi
        fi
        region_job "$prof" "$acct" "$reg" "$d" & BG_PIDS+=("$!"); running=$((running + 1))
    done
    if (( par > 1 )); then wait || true; BG_PIDS=(); fi
    local fails=0 c f gi=0 gf="$WORK/$acct/globals.json" gok=true gst=not-needed gmsg="" gn=0 greg="${regs[0]}"; i=0
    for reg in "${regs[@]}"; do   # in region order: per-region files only, no shared writes
        i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"
        if (( par > 1 )); then
            st="$(cat "$d/rc" 2>/dev/null || echo killed)"
            if [[ "$st" != 0 || ! -s "$d/scan.json" || ! -s "$d/rows.json" ]]; then
                [[ "$st" == 0 ]] && st="0, incomplete result"
                fails=$((fails + 1)); log_error "[$i/$n] $reg: failed (exit $st)"; region_failed "$acct" "$reg" "$d" "exit $st" "$prof"
            fi
            if [[ -s "$d/stats" ]]; then read -r c f <"$d/stats"; AWS_CALLS=$((AWS_CALLS + c)); AWS_FAILS=$((AWS_FAILS + f)); fi
        fi
        (( gi == 0 )) && [[ "$(jqv .rds_clusters "$d/scan.json")" != 0 ]] && { gi=$i; greg="$reg"; }
    done
    (( fails )) && log_warn "$acct: $fails of $n region(s) failed"
    # Aurora global databases: one describe-global-clusters per account, shared by the patch and the backup data
    echo '{}' >"$gf"
    if (( gi || DRY_RUN )); then
        if awsc "$gf" "$prof" "$greg" rds describe-global-clusters; then gst=ok; gn="$(jqv '.GlobalClusters // [] | length' "$gf")"
        else gok=false; gst=error; gmsg="$(err_of "$gf")"; echo '{}' >"$gf"; log_warn "$acct $greg: describe-global-clusters: $gmsg (Aurora clusters show global database \"unknown\")"; fi
    fi
    (( DRY_RUN )) && return 0
    cat "$WORK/$acct"/*/rows.json | jqv -s 'add // [] | any(.[]; .resource_type == "aurora-cluster")' | grep -q true || { gst=not-needed; gmsg=""; }
    i=0
    for reg in "${regs[@]}"; do
        i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"
        local extra=""; [[ $i == "$gi" && "$gok" == false ]] && extra="describe-global-clusters: $gmsg"
        build_region "$acct" "$reg" "$d" "$gf" "$gok" "$extra"
    done
    local nserv; nserv="$(cat "$WORK/$acct"/*/rs.json | jqv -s 'map(.servers) | add // 0')"
    region_summary "$acct" "$nserv"
    local calls=$((AWS_CALLS - c_acct)) utc gu gl; utc="$(jqv -rn --argjson e "$NOW" '$e | todate')"
    gu="$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$utc")"; gl="$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$utc")"
    cat "$WORK/$acct"/*/perr.jsonl >"$WORK/$acct/perr.all"
    # patch: the rds-patch-compliance --save-data document (schema rds_patch_compliance_data 1.1)
    jqv -n --arg s "$PATCH_SCHEMA" --arg tool "$SCRIPT_VERSION" --arg a "$acct" --arg p "${prof:-default}" --argjson now "$NOW" --arg utc "$utc" \
        --arg gu "$gu" --arg gl "$gl" --arg tz "$DISPLAY_TZ" --arg abbr "$TZ_LABEL" --argjson off "$TZ_OFFSET" --argjson calls "$calls" \
        --arg rmode "$( (( ALL_REGIONS )) && echo discover || echo explicit)" --argjson par "$PARALLEL" --argjson lc "$( [[ -e "$WORK/lc_unsupported" ]] && echo false || echo true)" \
        --arg greg "$greg" --arg gst "$gst" --arg gmsg "$gmsg" --argjson gn "$gn" --slurpfile g "$gf" \
        --slurpfile rs <(cat "$WORK/$acct"/*/rs.json) --slurpfile rows <(cat "$WORK/$acct"/*/rows.json) --slurpfile errs "$WORK/$acct/perr.all" \
        '($rows | add // []) as $R
        | {schema: $s, schema_version: 1, schema_minor: 1, script_version: $tool, collected_epoch: $now, collected_at: $utc,
           collected_utc: $gu, collected_local: $gl, tz: $tz, tz_abbr: $abbr, tz_offset: $off, read_only: "describe calls + sts get-caller-identity only",
           accounts: [{account: $a, profile: $p, collected_epoch: $now, collected_at: $utc}],
           settings: {max_behind: 2, warn_days: 180, filters: {engines: [], identifiers: []}, oracle_any_patch_line: false,
                      region_discovery: {mode: $rmode, probe_parallel: (if $rmode == "discover" then $par else null end)}, lifecycle_api: $lc, aws_calls: $calls},
           regions: ([$R[].region] | unique),
           region_status: [$rs[] | {account, profile: $p, region, status: (if .status == "error" then "probe-error" else .status end),
                                    probe_instances: .instances, probe_clusters: .clusters}],
           globals: (if $gst == "ok" then [($g[0].GlobalClusters // [])[] | {account: $a, id: .GlobalClusterIdentifier, arn: .GlobalClusterArn, engine: (.Engine // ""),
                      version: (.EngineVersion // ""), status: (.Status // ""),
                      members: [(.GlobalClusterMembers // [])[] | {arn: .DBClusterArn, region: (.DBClusterArn | split(":")[3]),
                                cluster: (.DBClusterArn | split(":")[-1]), role: (if .IsWriter then "primary" else "secondary" end)}]}] else [] end),
           global_lookup: [{account: $a, profile: $p, region: $greg, status: $gst, message: $gmsg, count: (if $gst == "ok" then $gn else 0 end)}],
           rows: $R, errors: $errs}' >"$WORK/p_$acct.json"
    # backup: the rds-backup-compliance --save-data document; docdb: DocumentDB / Neptune (same format)
    local kind
    for kind in backup docdb; do
        local rf=region.json rsf=resources.json of=orphans.json sch="$BACKUP_SCHEMA" scope=null
        [[ $kind == docdb ]] && { rf=dregion.json; rsf=dres.json; of=""; sch="$DATA_SCHEMA"; scope='"docdb,neptune"'; }
        jqv -n --arg s "$sch" --arg tool "$SCRIPT_VERSION" --arg a "$acct" --arg p "${prof:-default}" --argjson now "$NOW" --argjson scope "$scope" \
            --slurpfile regs <(cat "$WORK/$acct"/*/"$rf") --slurpfile res <(cat "$WORK/$acct"/*/"$rsf") --slurpfile orph <(if [[ -n "$of" ]]; then cat "$WORK/$acct"/*/"$of"; fi) \
            '{schema: $s, schema_version: 1, tool_version: $tool} + (if $scope then {scope: $scope} else {} end)
             + {collected_epoch: $now, collected_at: ($now | todate), accounts: [{account: $a, profile: $p, collected_epoch: $now}],
                regions: $regs, resources: [$res[][] | del(.arn)], orphans: [$orph[][]?]}' >"$WORK/${kind}_$acct.json"
    done
    jqv -n --arg s "$DATA_SCHEMA" --argjson v "$DATA_SCHEMA_VERSION" --arg tool "$SCRIPT_VERSION" --arg a "$acct" --arg p "${prof:-default}" --argjson now "$NOW" \
        --arg tz "$DISPLAY_TZ" --argjson calls "$calls" --argjson fails "$((AWS_FAILS - f_acct))" \
        --slurpfile P "$WORK/p_$acct.json" --slurpfile B "$WORK/backup_$acct.json" --slurpfile D "$WORK/docdb_$acct.json" \
        '{schema: $s, schema_version: $v, tool_version: $tool, collected_epoch: $now, collected_at: ($now | todate), tz: $tz,
          read_only: "describe / list calls + sts get-caller-identity only", aws_calls: $calls, aws_failures: $fails,
          accounts: [{account: $a, profile: $p, collected_epoch: $now}], patch: $P[0], backup: $B[0], docdb: $D[0]}' >"$WORK/data_$acct.json"
    log_info "$acct: $(jqv -r '"patch \(.patch.rows | length) server\(if (.patch.rows | length) == 1 then "" else "s" end), backup \(.backup.resources | length) RDS/Aurora + \(.docdb.resources | length) DocumentDB/Neptune, \(.aws_calls) AWS calls"' "$WORK/data_$acct.json")"
    DATA_FILES+=("$WORK/data_$acct.json")
}


# ---------------------------------------------------------------------------- merge input (0 AWS calls)
winpath() { local p="$1"; [[ -e "$p" ]] && { printf '%s' "$p"; return; }
            command -v cygpath >/dev/null 2>&1 && { cygpath -u -- "$p" 2>/dev/null | tr -d '\r'; return; }; printf '%s' "$p"; }
schema_of() { jq -r 'if type == "object" and (.schema | type) == "string" then .schema else "" end' -- "$1" 2>/dev/null | tr -d '\r' || true; }
declare -a PFILES=() BFILES=() DFILES=(); NIN=0
add_input() {   # add_input <file> <strict 0|1>
    local s; s="$(schema_of "$1")"
    case "$s" in
        "$PATCH_SCHEMA") PFILES+=("$1") ;; "$BACKUP_SCHEMA") BFILES+=("$1") ;;
        "$DATA_SCHEMA")
            if [[ "$(jqv -r '(.schema_version // 1) >= 2 and (.patch | type) == "object"' -- "$1" 2>/dev/null)" == true ]]; then
                local x="$WORK/in/$(( ${#PFILES[@]} + ${#BFILES[@]} + ${#DFILES[@]} ))"; mkdir -p "$x"   # same file name: patch warnings name it
                { jqv .patch -- "$1" >"$x/p" && jqv .backup -- "$1" >"$x/b" && jqv .docdb -- "$1" >"$x/d"; } || die 3 "Unreadable: $1"
                mkdir -p "$x/p_" && mv "$x/p" "$x/p_/${1##*/}"; PFILES+=("$x/p_/${1##*/}"); BFILES+=("$x/b"); DFILES+=("$x/d")
            else DFILES+=("$1"); fi ;;
        *) if (( $2 )); then die 3 "Not an rds_compliance --save-data file (or unreadable JSON): $1"; fi
           log_warn "skipping $1 (not a --save-data file)"; return 1 ;;
    esac
}
collect_merge_inputs() {
    local a p f found
    for a in "${MERGE_ARGS[@]}"; do
        p="$(winpath "$a")"
        if [[ -d "$p" ]]; then
            found=0
            for f in "$p"/*.json; do [[ -e "$f" ]] || continue; add_input "$f" 0 && { found=1; NIN=$((NIN + 1)); }; done
            (( found )) || die 3 "No --save-data files in directory: $a"
        elif [[ -f "$p" ]]; then add_input "$p" 1; NIN=$((NIN + 1))
        else die 3 "Merge input not found: $a"; fi
    done
    log_info "inputs: $(plural "$NIN" file)"
    local i=0 parts=()
    # patch: rds-patch-compliance lib/merge.jq (newest collection per account wins; status recomputed with --max-behind)
    : >"$WORK/p_in.jsonl"
    for f in "${PFILES[@]}"; do i=$((i + 1)); jqv -c --argjson i "$i" --arg l "${f##*/}" '{i: $i, label: $l, d: .}' -- "$f" >>"$WORK/p_in.jsonl" || die 3 "Unreadable: $f"; done
    if (( ${#PFILES[@]} )); then
        (cd "$LIBDIR" && jq -c -s --argjson mb "${MAX_BEHIND:-null}" --argjson oal "${ORACLE_ANY:-null}" -f patch_merge.jq "$WORK/p_in.jsonl") | tr -d '\r' >"$WORK/patch.json" \
            || die 3 "Cannot merge the patch files"
    else jqv -n --argjson mb "${MAX_BEHIND:-2}" --argjson oal "${ORACLE_ANY:-false}" '{accounts: [], rows: [], errors: [], max_behind: $mb, oracle_any_patch_line: $oal}' >"$WORK/patch.json"; fi
    # backup and DocumentDB/Neptune: rds-backup-compliance lib/merge.jq, each source on its own (newest per account wins)
    merge_backup() { local out="$1"; shift; local j=0; parts=()
        for f in "$@"; do j=$((j + 1)); jqv -c --argjson i "$j" '{i: $i, d: .}' -- "$f" >"$WORK/$out.m$j.json" || die 3 "Unreadable: $f"; parts+=("$WORK/$out.m$j.json"); done
        if (( j )); then jqv -s -f "$LIBDIR/backup_merge.jq" "${parts[@]}" >"$WORK/$out.json" || die 3 "Cannot merge the $out files"
        else echo '{"accounts":[],"regions":[],"resources":[],"orphans":[],"replaced":[]}' >"$WORK/$out.json"; fi; }
    merge_backup backup "${BFILES[@]}"; merge_backup docdb "${DFILES[@]}"
    local r
    while IFS= read -r r; do [[ -n "$r" ]] && log_warn "$r"; done < <(jqv -r '.superseded[]? | "patch, account \(.account): \(.dropped) ignored, \(.kept) is newer"' "$WORK/patch.json"
        jqv -r '.replaced[]? | "backup, account \(.account): an older collection was ignored (newer file wins)"' "$WORK/backup.json"
        jqv -r '.replaced[]? | "DocumentDB/Neptune, account \(.account): an older collection was ignored (newer file wins)"' "$WORK/docdb.json")
    # rds-backup-compliance skips DocumentDB / Neptune; drop any so the collector is the only source for them
    jqv -s '{accounts: (.[0].accounts + .[1].accounts), regions: (.[0].regions + .[1].regions), orphans: [],
             resources: ([ .[0].resources[] | select(.engine | test("^(docdb|neptune)") | not) ] + [ .[1].resources[] | select(.engine | test("^(docdb|neptune)")) ])}' \
        "$WORK/backup.json" "$WORK/docdb.json" >"$WORK/bdata.json"
    jqv -r --arg mode rows --argjson now "$NOW" --argjson cfg "$CFG" --arg tool "$SCRIPT_VERSION" --arg page "" -f "$LIBDIR/backup.jq" "$WORK/bdata.json" >"$WORK/brows.json" \
        || die 3 "Cannot evaluate the backup data"
}

# ---------------------------------------------------------------------------- output
abs_dir() {   # absolute, normalised directory (no //, ./, ..; ~ expanded) - CloudShell and Git Bash
    local p="$1" out="" part; local -a parts=() keep=()
    [[ "$p" == "~" || "$p" == \~/* ]] && p="$HOME${p#\~}"
    [[ "$p" == /* ]] || p="$PWD/$p"
    IFS='/' read -r -a parts <<<"$p"
    for part in "${parts[@]}"; do
        case "$part" in ''|.) ;; ..) (( ${#keep[@]} )) && unset 'keep[${#keep[@]}-1]' ;; *) keep+=("$part") ;; esac
    done
    for part in "${keep[@]}"; do out+="/$part"; done
    printf '%s' "${out:-/}"
}
# ---------------------------------------------------------------------------- compliance exceptions (shared by
# rds-patch-compliance, rds-backup-compliance and rds-compliance-report; same file format in all three)
# compliance_exceptions.conf, one entry per line:  account_id | identifier | scope | expires | reason
#   all five required; scope patch, backup or patch,backup; expires YYYY-MM-DD (UTC, last valid day); # comments
# Strict: any bad line stops the run (exit 1) naming file:line. Applied at report time only (saved data is unchanged).
exc_trim() { local -n _v="$1"; _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"; }
load_exceptions() {   # -> EXC_JSON: "null" (feature off: no file) or a JSON array of entries; EXC_PATH = the file used
    local f="$EXC_FILE" line n=0 acct id scope exp reason s y m d dim k tsv=""
    local -a sc=()
    local -A seen=()
    if [[ -z "$f" ]]; then f="$SCRIPT_DIR/compliance_exceptions.conf"; [[ -f "$f" ]] || return 0; fi
    [[ -f "$f" && -r "$f" ]] || die 1 "Exceptions file not readable: $f"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" == *'|'*'|'*'|'*'|'* ]] || die 1 "Exceptions $f:$n: expected 5 fields 'account_id | identifier | scope | expires | reason'"
        IFS='|' read -r acct id scope exp reason <<<"$line"
        exc_trim acct; exc_trim id; exc_trim scope; exc_trim exp; reason="${reason//[$'\001'-$'\037']/ }"; exc_trim reason
        [[ -n "$acct" && -n "$id" && -n "$scope" && -n "$exp" && -n "$reason" ]] \
            || die 1 "Exceptions $f:$n: missing field (all of account_id, identifier, scope, expires, reason are required)"
        [[ "$acct" =~ ^[0-9]{12}$ ]] || die 1 "Exceptions $f:$n: account_id must be 12 digits (got '$acct')"
        [[ "$id" =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] \
            || die 1 "Exceptions $f:$n: identifier '$id' is not a DB instance / cluster identifier (letters, digits, hyphens; no wildcards)"
        scope="${scope,,}"; scope="${scope//[[:space:]]/}"; IFS=',' read -r -a sc <<<"$scope"
        (( ${#sc[@]} )) || die 1 "Exceptions $f:$n: scope must be patch, backup or patch,backup"
        k=""; for s in "${sc[@]}"; do
            [[ "$s" == patch || "$s" == backup ]] || die 1 "Exceptions $f:$n: scope must be patch, backup or patch,backup (got '$scope')"
            [[ ",$k," == *",$s,"* ]] && die 1 "Exceptions $f:$n: scope lists '$s' twice"
            k+="${k:+,}$s"
        done
        scope="$k"
        [[ "$exp" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || die 1 "Exceptions $f:$n: expires must be a date YYYY-MM-DD (got '$exp'); an expiry date is mandatory"
        y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
        case "$m" in 1|3|5|7|8|10|12) dim=31 ;; 4|6|9|11) dim=30 ;;
            2) if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then dim=29; else dim=28; fi ;; *) dim=0 ;; esac
        (( m >= 1 && m <= 12 && d >= 1 && d <= dim && y >= 2000 )) || die 1 "Exceptions $f:$n: expires '$exp' is not a valid date"
        for s in "${sc[@]}"; do
            k="$acct|${id,,}|$s"
            [[ -n "${seen[$k]:-}" ]] && die 1 "Exceptions $f:$n: duplicate entry for $acct $id ($s), already on line ${seen[$k]}"
            seen[$k]=$n
        done
        tsv+="$n"$'\t'"$acct"$'\t'"$id"$'\t'"$scope"$'\t'"$exp"$'\t'"$reason"$'\n'
    done <"$f"
    EXC_PATH="$f"
    EXC_JSON="$(printf '%s' "$tsv" | jq -Rcs 'split("\n") | map(select(. != "") | split("\t")
        | {line: (.[0] | tonumber), account: .[1], identifier: .[2], scopes: (.[3] | split(",")), expires: .[4], reason: (.[5:] | join(" "))})' | tr -d '\r')" \
        || die 1 "Exceptions $f: cannot convert the entries (jq)"
    return 0
}
exc_ready() {   # write the validated entries next to the work files once; jq reads them as $ARGS.named.exc
    [[ "$EXC_JSON" != null && -n "$WORK" ]] || return 0
    printf '%s' "$EXC_JSON" >"$WORK/exceptions.json"; EXC_ARGS=(--slurpfile exc "$WORK/exceptions.json"); return 0
}

output_block() {
    (( ${#WRITTEN[@]} )) || return 0
    local f n=${#WRITTEN[@]}
    printf 'Output (%d file%s):\n' "$n" "$( (( n == 1 )) || echo s)" >&2
    for f in "${WRITTEN[@]}"; do printf '  %s/%s\n' "$(abs_dir "$(dirname -- "$f")")" "${f##*/}" >&2; done
    if [[ -n "$LOG_FILE" ]]; then printf 'wrote %s\n' "${WRITTEN[@]}" >>"$LOG_FILE" 2>/dev/null || true; fi
}
render() {   # render <mode> -> stdout
    jqv -nr --arg mode "$1" --slurpfile P "$WORK/patch.json" --slurpfile B "$WORK/brows.json" --slurpfile BD "$WORK/backup.json" --slurpfile DD "$WORK/docdb.json" \
        --argjson now "$NOW" --argjson cfg "$CFG" --arg tool "$SCRIPT_VERSION" --rawfile page "$LIBDIR/page.js" --rawfile page_css "$LIBDIR/page.css" \
        "${EXC_ARGS[@]}" -f "$LIBDIR/report.jq"
}
write_out() { local f="$1"; shift; "$@" >"$f" || die 4 "Cannot write $f"; WRITTEN+=("$f"); }

main() {
    if (( $# == 0 )); then usage; exit 1; fi
    parse_args "$@"
    command -v jq >/dev/null 2>&1 || die 2 "jq not found"
    local f; for f in backup.jq backup_merge.jq backup_collect.jq patch_merge.jq patch_compliance.jq versions.jq collect_docdb.jq report.jq page.js page.css; do
        [[ -r "$LIBDIR/$f" ]] || die 2 "Missing $LIBDIR/$f - keep the lib/ folder next to the script"; done
    (( MERGE )) || (( DRY_RUN )) || command -v aws >/dev/null 2>&1 || die 2 "aws CLI not found"
    if (( MERGE )); then   # exceptions are applied when the report is built; the saved data never changes
        load_exceptions
        [[ "$EXC_JSON" != null ]] && log_info "Exceptions file $EXC_PATH: $(jqv -r 'length' <<<"$EXC_JSON") entries"
    elif [[ -n "$EXC_FILE" ]]; then log_warn "--exceptions is used with --merge (report time); ignored for --save-data"; fi
    NOW="${RDS_CR_NOW:-$(date -u +%s)}"; STAMP="$(date -u -d "@$NOW" +%Y%m%d_%H%M%S 2>/dev/null || date -u +%Y%m%d_%H%M%S)"; tz_setup; CFG="$(cfg_json)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_cr.XXXXXX")"
    trap '(( KEEP_WORKDIR )) && echo "workdir kept: $WORK" >&2 || rm -rf -- "$WORK"' EXIT
    trap '(( ${#BG_PIDS[@]} )) && kill "${BG_PIDS[@]}" 2>/dev/null; exit 130' INT TERM
    HAVE_WAIT_N=0; [[ -z "${RDS_CR_NO_WAIT_N:-}" ]] && (( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[1] >= 3 )) && HAVE_WAIT_N=1
    [[ -n "$OUTPUT_DIR" ]] && { mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || die 4 "Cannot create $OUTPUT_DIR"; }
    log_info "$SCRIPT_NAME $SCRIPT_VERSION started $(when "$NOW")"

    if (( ! MERGE )); then
        (( ${#PROFILES[@]} )) || PROFILES=("")
        local p ok=0; for p in "${PROFILES[@]}"; do scan_profile "$p" && ok=$((ok + 1)); done
        (( DRY_RUN )) && exit 0
        (( ok )) || die 2 "No profile could be scanned"
        log_info "AWS calls: $AWS_CALLS ($AWS_FAILS failed)"
        local df a target
        for df in "${DATA_FILES[@]}"; do
            a="$(jqv -r '.accounts[0].account' "$df")"
            target="${OUTPUT_DIR:-.}/rds_compliance_${a}_$(date -u -d "@$NOW" +%Y%m%d 2>/dev/null || date -u +%Y%m%d).json"
            if [[ -n "$SAVE_DATA_FILE" ]]; then target="$SAVE_DATA_FILE"; (( ${#DATA_FILES[@]} > 1 )) && target="${SAVE_DATA_FILE%.json}_$a.json"; fi
            write_out "$target" jqv . "$df"
        done
        output_block; exit 0
    fi

    exc_ready
    collect_merge_inputs
    local na tag base
    na="$(render json | jqv '.accounts | length')"
    if (( na == 1 )); then tag="$(render json | jqv -r '.accounts[0].account_id')"; else tag="${na}_accounts"; fi
    base="$OUTPUT_DIR/${PREFIX}_${tag}_${STAMP}"
    write_out "$base.html" render html
    write_out "$base.txt" render txt
    write_out "${base}_servers.csv" csv_out csv
    write_out "${base}_accounts.csv" csv_out acsv
    write_out "${base}_regions.csv" csv_out rcsv
    write_out "${base}_engines.csv" csv_out ecsv
    render txt >&2
    log_info "AWS calls: 0 (offline merge)"
    log_info "$(render sum)"
    if [[ "$EXC_JSON" != null ]]; then
        local l; while IFS=$'\t' read -r f l; do [[ -n "$l" ]] && if [[ "$f" == W ]]; then log_warn "$l"; else log_info "$l"; fi; done < <(render exclog | sed "s|@FILE@|${EXC_PATH##*/}|")
    fi
    output_block
    exit 0
}
# shellcheck disable=SC2329  # called through write_out
csv_out() { printf '\xef\xbb\xbf'; render "$1" | sed 's/$/\r/'; }   # Excel: UTF-8 BOM, CRLF (RFC 4180)

main "$@"
