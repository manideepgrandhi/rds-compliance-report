#!/usr/bin/env bash
#
# rds_compliance_report.sh - one lightweight patch + backup compliance report for Aurora, RDS, Multi-AZ clusters,
# DocumentDB and Neptune, built OFFLINE from the --save-data files of the two full tools:
#   rds_patch_<ACCT>_<YYYYMMDD>.json    rds-patch-compliance  --save-data   (schema rds_patch_compliance_data)
#   rds_backup_<ACCT>_<YYYYMMDD>.json   rds-backup-compliance --save-data   (schema rds_backup_compliance_data, v1.5.1+)
#   rds_compliance_<ACCT>_<YYYYMMDD>.json  this script --save-data: DocumentDB / Neptune backups only (rds-backup-compliance
#                                       skips those engines). READ-ONLY: sts get-caller-identity, ec2 describe-regions (-A),
#                                       rds describe-db-clusters / describe-db-cluster-snapshots, backup list-backup-vaults /
#                                       list-recovery-points-by-backup-vault.
# Rules: none of its own. Patch status = rds-patch-compliance (versions behind > --max-behind is NON-COMPLIANT, a deprecated
# version is UNKNOWN); backup status = rds-backup-compliance lib/backup.jq (retention mismatch, excess backups and
# over-retention are warnings). The jq of both tools is copied unchanged into lib/.
# Exit: 0 ok, 1 usage, 2 pre-check, 3 bad --merge input, 4 output error, 130 interrupted.

# shellcheck disable=SC2016,SC2034  # jq programs are single-quoted on purpose; KEEP_WORKDIR is read in the EXIT trap
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIBDIR="${RDS_CR_LIB:-$SCRIPT_DIR/lib}"
readonly DATA_SCHEMA="rds_compliance_data" DATA_SCHEMA_VERSION=1
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

Collect DocumentDB / Neptune backup data (CloudShell, read-only):
  $SCRIPT_NAME --save-data [FILE] [-P PROFILE[,..]] [-r REGION[,..] | -A] [--parallel N] [-o DIR] [-v]

Build the report from saved files (0 AWS calls; CloudShell, Linux, macOS, Git Bash):
  $SCRIPT_NAME --merge FILE|DIR [FILE|DIR ...] -o DIR [options]
    inputs: rds_patch_*.json (rds-patch-compliance --save-data), rds_backup_*.json (rds-backup-compliance v1.5.1+
    --save-data), rds_compliance_*.json (this script --save-data). Per account and source the newest collection wins.

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
        tz) DISPLAY_TZ="$v" ;;
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
            --max-behind|--daily|--daily-max-age|--weekly|--monthly|--yearly|--weekly-days|--monthly-days|--daily-retention-days|--weekly-retention-days|--monthly-retention-days|--retention-tolerance-days|--weekly-weekday|--monthly-rule|--tolerance-days|--parallel|--weekly-window-days|--prefix|--tz|--aws-timeout|--max-attempts)
                need_arg "$1" $#; set_opt "${1#--}" "$2"; shift ;;
            --*=*) local k="${1%%=*}"; set_opt "${k#--}" "${1#*=}" || die 1 "Unknown option: $1" ;;
            *) die 1 "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    (( WEEKLY_MIN_DAYS <= WEEKLY_MAX_DAYS && WEEKLY_MAX_DAYS < MONTHLY_MIN_DAYS && MONTHLY_MIN_DAYS <= MONTHLY_MAX_DAYS )) \
        || die 1 "Need weekly-days MIN <= MAX < monthly-days MIN <= MAX (got weekly $WEEKLY_MIN_DAYS-$WEEKLY_MAX_DAYS, monthly $MONTHLY_MIN_DAYS-$MONTHLY_MAX_DAYS)"
    (( MERGE || SAVE_DATA )) || die 1 "Choose --save-data (collect DocumentDB / Neptune data) or --merge FILE|DIR ... (build the report); see --help"
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

scan_region() {   # scan_region <profile> <account> <region> <dir> -> <dir>/resources.json, <dir>/region.json
    local prof="$1" acct="$2" reg="$3" d="$4" e n; local -a errs=()
    local c0=$AWS_CALLS f0=$AWS_FAILS csnap_ok=true backup_ok=true
    echo '{}' >"$d/c.json"; echo '{}' >"$d/cs.json"; echo '[]' >"$d/rp.json"
    awsc "$d/c.json" "$prof" "$reg" rds describe-db-clusters --filters Name=engine,Values=docdb,neptune \
        || { errs+=("describe-db-clusters: $(err_of "$d/c.json")"); echo '{}' >"$d/c.json"; }
    n="$(jqv '[.DBClusters[]? | select(.Engine // "" | test("^(docdb|neptune)"))] | length' "$d/c.json")"
    (( DRY_RUN )) && n=1
    if (( n > 0 )); then
        awsc "$d/cs.json" "$prof" "$reg" rds describe-db-cluster-snapshots --filters Name=engine,Values=docdb,neptune \
            || { csnap_ok=false; errs+=("describe-db-cluster-snapshots: $(err_of "$d/cs.json")"); echo '{}' >"$d/cs.json"; }
        if awsc "$d/v.json" "$prof" "$reg" backup list-backup-vaults; then
            local v k=0
            while IFS= read -r v; do
                [[ -n "$v" ]] || continue; k=$((k + 1))
                awsc "$d/rp$k.json" "$prof" "$reg" backup list-recovery-points-by-backup-vault --backup-vault-name "$v" \
                    || { backup_ok=false; errs+=("list-recovery-points-by-backup-vault $v: $(err_of "$d/rp$k.json")"); echo '{}' >"$d/rp$k.json"; }
            done < <(jqv -r '.BackupVaultList[]?.BackupVaultName' "$d/v.json")
            if (( k )); then jqv -s '[ .[].RecoveryPoints[]? | select(.ResourceArn // "" | test(":rds:")) ]' "$d"/rp[0-9]*.json >"$d/rp.json"; fi
        else backup_ok=false; errs+=("list-backup-vaults: $(err_of "$d/v.json")"); fi
    fi
    jqv -n --arg acct "$acct" --arg region "$reg" --slurpfile clusters "$d/c.json" --slurpfile csnaps "$d/cs.json" --slurpfile rps "$d/rp.json" \
        --argjson csnap_ok "$csnap_ok" --argjson backup_ok "$backup_ok" -f "$LIBDIR/collect_docdb.jq" >"$d/resources.json"
    local status; n="$(jqv length "$d/resources.json")"
    if (( ${#errs[@]} )); then status=error; elif (( n > 0 )); then status="with databases"; else status=empty; fi
    for e in "${errs[@]}"; do log_warn "$acct $reg: $e"; done
    region_progress "$reg" "$d/resources.json" "${errs[@]}"
    jqv -n --arg a "$acct" --arg r "$reg" --arg s "$status" --argjson n "$n" --argjson e "$(json_array "${errs[@]}")" --argjson so "$csnap_ok" \
        '{account: $a, region: $r, status: $s, resources: $n, errors: $e, snapshot_scan: $so, existing: null}' >"$d/region.json"
    echo "$((AWS_CALLS - c0)) $((AWS_FAILS - f0))" >"$d/stats"
}

region_job() {   # background job: scan_region in a subshell; <dir>/rc marks a normal finish
    local d="$4"
    trap - EXIT INT TERM; set +e
    ( set -e; shopt -s inherit_errexit 2>/dev/null || true; scan_region "$@" ); echo $? >"$d/rc"
}

region_failed() {   # placeholder result so the other regions still report
    echo '[]' >"$3/resources.json"
    jqv -n --arg a "$1" --arg r "$2" --arg e "region scan failed: $4" \
        '{account: $a, region: $r, status: "error", resources: 0, errors: [$e], snapshot_scan: false, existing: null}' >"$3/region.json"
}

region_progress() {   # one line per region with resources (every region with -v); errors always shown
    local reg="$1" res="$2"; shift 2
    local line secs=$(( SECONDS - ${REG_T0:-$SECONDS} ))
    line="$(jqv -r '([.[] | select(.engine | startswith("docdb"))] | length) as $d | ([.[] | select(.engine | startswith("neptune"))] | length) as $n
        | ([.[].snapshots[]? | select(.kind != "backup")] | length) as $s | ([.[].snapshots[]? | select(.kind == "backup")] | length) as $b
        | if $d + $n == 0 then "(empty)"
          else "\($d) DocumentDB + \($n) Neptune cluster\(if $d + $n == 1 then "" else "s" end), \($s) snapshot\(if $s == 1 then "" else "s" end), \($b) recovery point\(if $b == 1 then "" else "s" end)" end' "$res")" || true
    [[ -n "$line" ]] || line="failed: unreadable AWS output"
    [[ "$line" == "(empty)" && $# -eq 0 && "$VERBOSE" != 1 ]] && return 0
    [[ "$line" == "(empty)" ]] || line+=" (${secs}s)"
    if (( $# )); then line+=" - ERROR: $(IFS='; '; echo "$*")"; [[ "$line" == *"(empty)"* ]] && line="${line/(empty)/(no data)}"; fi
    log_info "[$REG_I/$REG_N] $reg: $line"
}

region_summary() {   # "17 regions scanned, 15 empty: a, b, c" (+ failed regions)
    log_info "$1: $(jqv -rs '(map(select(.status == "empty") | .region)) as $e | (map(select(.status == "error") | .region)) as $f
        | "\(length) region\(if length == 1 then "" else "s" end) scanned, \(map(.resources) | add) DocumentDB/Neptune cluster(s), \($e | length) empty\(if ($e | length) > 0 then ": " + ($e | join(", ")) else "" end)"
          + (if ($f | length) > 0 then "; \($f | length) failed: \($f | join(", "))" else "" end)' "$WORK/$1"/*/region.json)"
}

scan_profile() {   # scan_profile <profile> -> $WORK/data_<account>.json
    local prof="$1" acct reg d i=0 st idf="$WORK/id_${1:-default}.json"; local -a regs=()
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
    log_info "$acct (${prof:-default}): scanning $n region(s) for DocumentDB / Neptune${par:+, up to $par at a time}"
    for reg in "${regs[@]}"; do
        i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"; mkdir -p "$d"; REG_I=$i; REG_N=$n; REG_T0=$SECONDS
        if (( par == 1 )); then scan_region "$prof" "$acct" "$reg" "$d"; echo 0 >"$d/rc"; continue; fi
        if (( running >= par )); then
            if (( HAVE_WAIT_N )); then wait -n || true; running=$((running - 1)); else wait || true; running=0; fi
        fi
        region_job "$prof" "$acct" "$reg" "$d" & BG_PIDS+=("$!"); running=$((running + 1))
    done
    (( DRY_RUN )) && return 0
    if (( par > 1 )); then
        wait || true; BG_PIDS=()
        local fails=0 c f; i=0
        for reg in "${regs[@]}"; do   # combine in region order: per-region files only, no shared writes
            i=$((i + 1)); printf -v d '%s/%s/%04d' "$WORK" "$acct" "$i"
            st="$(cat "$d/rc" 2>/dev/null || echo killed)"
            if [[ "$st" != 0 || ! -s "$d/region.json" || ! -s "$d/resources.json" ]]; then
                [[ "$st" == 0 ]] && st="0, incomplete result"
                fails=$((fails + 1)); log_error "[$i/$n] $reg: failed (exit $st)"; region_failed "$acct" "$reg" "$d" "exit $st"
            fi
            if [[ -s "$d/stats" ]]; then read -r c f <"$d/stats"; AWS_CALLS=$((AWS_CALLS + c)); AWS_FAILS=$((AWS_FAILS + f)); fi
        done
        (( fails )) && log_warn "$acct: $fails of $n region(s) failed"
    fi
    region_summary "$acct"
    jqv -n --arg s "$DATA_SCHEMA" --argjson v "$DATA_SCHEMA_VERSION" --arg tool "$SCRIPT_VERSION" --arg a "$acct" --arg p "${prof:-default}" --argjson now "$NOW" \
        '{schema: $s, schema_version: $v, tool_version: $tool, scope: "docdb,neptune", collected_epoch: $now, collected_at: ($now | todate),
          accounts: [{account: $a, profile: $p, collected_epoch: $now}], regions: [ inputs ], resources: [], orphans: []}' "$WORK/$acct"/*/region.json >"$WORK/hdr_$acct.json"
    jqv -s '.[0] + {resources: [ .[1:][][] ]}' "$WORK/hdr_$acct.json" "$WORK/$acct"/*/resources.json >"$WORK/data_$acct.json"
    DATA_FILES+=("$WORK/data_$acct.json")
}

# ---------------------------------------------------------------------------- merge input (0 AWS calls)
winpath() { local p="$1"; [[ -e "$p" ]] && { printf '%s' "$p"; return; }
            command -v cygpath >/dev/null 2>&1 && { cygpath -u -- "$p" 2>/dev/null | tr -d '\r'; return; }; printf '%s' "$p"; }
schema_of() { jq -r 'if type == "object" and (.schema | type) == "string" then .schema else "" end' -- "$1" 2>/dev/null | tr -d '\r' || true; }
declare -a PFILES=() BFILES=() DFILES=()
add_input() {   # add_input <file> <strict 0|1>
    local s; s="$(schema_of "$1")"
    case "$s" in
        "$PATCH_SCHEMA") PFILES+=("$1") ;; "$BACKUP_SCHEMA") BFILES+=("$1") ;; "$DATA_SCHEMA") DFILES+=("$1") ;;
        *) if (( $2 )); then die 3 "Not a patch, backup or DocumentDB/Neptune --save-data file (or unreadable JSON): $1"; fi
           log_warn "skipping $1 (not a --save-data file)"; return 1 ;;
    esac
}
collect_merge_inputs() {
    local a p f found
    for a in "${MERGE_ARGS[@]}"; do
        p="$(winpath "$a")"
        if [[ -d "$p" ]]; then
            found=0
            for f in "$p"/*.json; do [[ -e "$f" ]] || continue; add_input "$f" 0 && found=1; done
            (( found )) || die 3 "No --save-data files in directory: $a"
        elif [[ -f "$p" ]]; then add_input "$p" 1
        else die 3 "Merge input not found: $a"; fi
    done
    log_info "inputs: ${#PFILES[@]} patch, ${#BFILES[@]} backup, ${#DFILES[@]} DocumentDB/Neptune file(s)"
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
        -f "$LIBDIR/report.jq"
}
write_out() { local f="$1"; shift; "$@" >"$f" || die 4 "Cannot write $f"; WRITTEN+=("$f"); }

main() {
    parse_args "$@"
    command -v jq >/dev/null 2>&1 || die 2 "jq not found"
    local f; for f in backup.jq backup_merge.jq patch_merge.jq versions.jq collect_docdb.jq report.jq page.js page.css; do
        [[ -r "$LIBDIR/$f" ]] || die 2 "Missing $LIBDIR/$f - keep the lib/ folder next to the script"; done
    (( MERGE )) || (( DRY_RUN )) || command -v aws >/dev/null 2>&1 || die 2 "aws CLI not found"
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
    output_block
    exit 0
}
# shellcheck disable=SC2329  # called through write_out
csv_out() { printf '\xef\xbb\xbf'; render "$1" | sed 's/$/\r/'; }   # Excel: UTF-8 BOM, CRLF (RFC 4180)

main "$@"
