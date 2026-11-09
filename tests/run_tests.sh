#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # checks are eval-ed strings
# Offline tests: mock aws CLI + fixtures, shellcheck, headless Chrome (optional). Usage: bash tests/run_tests.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"; S="$ROOT/rds_compliance_report.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $1"; fi; }
export RDS_CR_NOW=1793700000 MOCK_NOW=1793700000 RDS_CR_NO_WAIT_N=1
MPATH="$HERE/mock:$PATH"
col() { jq -Rr --arg id "$2" --arg a "${3:-111111111111}" --argjson c "$4" 'sub("^\ufeff";"")|sub("\r$";"")|[splits(",(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)")|ltrimstr("\"")|rtrimstr("\"")]|select(.[5]==$id and .[0]==$a)|.[$c]' "$1"; }
run() { "$S" "$@" >"$T/out" 2>"$T/err"; echo $? >"$T/rc"; }
rc() { cat "$T/rc"; }

echo "== usage"
run --version; ok "--version" '[[ $(rc) == 0 ]] && grep -q "1.2.0" "$T/out"'
run; ok "no args -> usage, 1" '[[ $(rc) == 1 ]] && grep -q "save-data" "$T/out"'
run -A; ok "no mode -> 1" '[[ $(rc) == 1 ]]'
run --merge "$HERE/fixtures"; ok "merge without -o -> 1" '[[ $(rc) == 1 ]]'
run --bogus; ok "unknown option -> 1" '[[ $(rc) == 1 ]]'

echo "== merge fixtures"
mkdir -p "$T/fakeaws"; printf '#!/bin/sh\necho "$@" >>"%s/awscalls"; exit 1\n' "$T" >"$T/fakeaws/aws"; chmod +x "$T/fakeaws/aws"
O="$T/out dir"; PATH="$T/fakeaws:$PATH" run --merge "$HERE/fixtures" -o "$O"
ok "merge exit 0" '[[ $(rc) == 0 ]]'
ok "0 aws calls" '[[ ! -e "$T/awscalls" ]]'
ok "6 outputs, N_accounts name" '[[ $(ls "$O" | grep -c "^rds_compliance_report_2_accounts_20261103_100000") == 6 ]]'
SV="$(ls "$O"/*_servers.csv)"; AC="$(ls "$O"/*_accounts.csv)"; TX="$(ls "$O"/*.txt)"; H="$(ls "$O"/*.html)"
ok "32 servers" '[[ $(( $(wc -l <"$SV") - 1 )) == 32 ]]'
ok "summary 58.6% / 40%" 'grep -q "58.6%" "$TX" && grep -q "40%" "$TX"'
ok "account 111 61.5/44" 'grep -q "\"111111111111\",.*,\"28\",\"61.5\",.*\"44\"" "$AC"'
ok "account 222 33.3/0" 'grep -q "\"222222222222\",.*,\"4\",\"33.3\",.*,\"0\",\"0\",\"0\",\"1\"" "$AC"'
ok "newest patch file wins (warning)" 'grep -qi "newer\|newest\|superseded" "$T/err"'
ok "old file values not used" '[[ $(col "$SV" billing-aurora-mysql 111111111111 6) == Compliant ]]'
ok "neptune retention 1 -> Fail" '[[ $(col "$SV" graph-neptune 111111111111 11) == Fail ]]'
ok "new docdb -> Not yet due" '[[ $(col "$SV" new-docdb 111111111111 11) == "Not yet due" ]]'
ok "docdb compliant -> OK" '[[ $(col "$SV" catalog-docdb 111111111111 11) == OK ]]'
ok "docdb replica us-west-2 OK" '[[ $(col "$SV" catalog-docdb-dr 111111111111 11) == OK ]]'
ok "docdb monthly fail (222)" '[[ $(col "$SV" dev-docdb 222222222222 11) == Fail ]]'
ok "retention mismatch = Warning" '[[ $(col "$SV" orders-aurora-pg15 111111111111 11) == Warning ]]'
ok "deprecated -> Unknown" '[[ $(col "$SV" old-aurora-pg11 111111111111 6) == Unknown ]]'
ok "no backup file reason" '[[ $(col "$SV" hr-sql 222222222222 12) == "no backup data for this account" ]]'
ok "not in data reason" '[[ $(col "$SV" hr-sql 111111111111 12) == "not in the backup data of this account" ]]'
ok "no patch data for docdb new" '[[ $(col "$SV" new-docdb 111111111111 6) == "No data" ]]'
ok "aurora ignored by docdb collector" '! grep -q "aurora-ignore" "$SV"'
ok "csv BOM" '[[ $(head -c3 "$SV" | od -An -tx1 | tr -d " ") == efbbbf ]]'
ok "csv CRLF" 'head -1 "$SV" | grep -q $'"'"'\r$'"'"''
ok "dotted version wrapped" 'grep -q "\"=\"\"15.8\"\"\"" "$SV"'
ok "full paths printed" 'grep -q "$O/rds_compliance_report_2_accounts" "$T/err" "$T/out"'
ok "UTC + IST" 'grep -q "IST" "$TX" && grep -q "UTC" "$TX"'
ok "html single file, no external refs" '! grep -qiE "<(link|script)[^>]+(src|href)=\"?https?:" "$H"'
ok "html no expandable rows" '! grep -q "<details" "$H"'

echo "== options"
run --merge "$HERE/fixtures" -o "$T/mb0" --max-behind 0
ok "--max-behind 0 lowers patch %" '! grep -q "58.6%" "$T/mb0"/*.txt && [[ $(col "$T"/mb0/*_servers.csv billing-aurora-mysql 111111111111 6) == Non-compliant ]]'
run --merge "$HERE/fixtures" -o "$T/mb9" --max-behind 9
ok "--max-behind 9 more compliant" '[[ $(col "$T"/mb9/*_servers.csv hr-sql 111111111111 6) == Compliant ]]'
run --merge "$HERE/fixtures" -o "$T/oal" --oracle-any-patch-line
ok "--oracle-any-patch-line runs" '[[ $(rc) == 0 ]]'
run --merge "$HERE/fixtures/rds_patch_222222222222_20261103.json" -o "$T/one"
ok "single account name" 'ls "$T/one" | grep -q "_222222222222_20261103_100000.html"'
ok "missing source = No data, excluded" 'grep -q "No data" "$T"/one/*.txt'
run --merge "$HERE/fixtures" -o "$T/cfg" --monthly 0 --yearly 0
ok "backup thresholds passed" '[[ $(col "$T"/cfg/*_servers.csv dev-docdb 222222222222 11) != Fail ]]'

echo "== bad input -> 3"
run --merge "$T/nope" -o "$T/x"; ok "missing path" '[[ $(rc) == 3 ]]'
mkdir -p "$T/empty"; run --merge "$T/empty" -o "$T/x"; ok "empty dir" '[[ $(rc) == 3 ]]'
echo 'not json' >"$T/rds_patch_1_x.json"; run --merge "$T/rds_patch_1_x.json" -o "$T/x"; ok "not json" '[[ $(rc) == 3 ]]'
echo '{"schema":"other"}' >"$T/w.json"; run --merge "$T/w.json" -o "$T/x"; ok "wrong schema" '[[ $(rc) == 3 ]]'

echo "== CRLF jq (Git Bash) + escaping"
mkdir -p "$T/crjq"; J="$(command -v jq)"; printf '#!/bin/sh\n"%s" "$@" | sed "s/$/\\r/"\n' "$J" >"$T/crjq/jq"; chmod +x "$T/crjq/jq"
PATH="$T/crjq:$PATH" run --merge "$HERE/fixtures" -o "$T/cr"
ok "CRLF jq merge exit 0" '[[ $(rc) == 0 ]]'
ok "CRLF jq same summary" 'grep -q "58.6%" "$T"/cr/*.txt && [[ $(ls "$T/cr" | wc -l) == 6 ]]'
mkdir -p "$T/inj"; cp "$HERE"/fixtures/*.json "$T/inj/"; jq '.resources[0].id="<script>alert(1)</script>=HYPERLINK(\"x\")"' "$HERE/fixtures/rds_compliance_222222222222_20261103.json" >"$T/inj/rds_compliance_222222222222_20261103.json"
run --merge "$T/inj" -o "$T/injo"; IH="$(ls "$T"/injo/*.html)"
ok "no raw <script>alert in html" '! grep -q "<script>alert" "$IH"'
ok "injected value present escaped" 'grep -q "u003cscript" "$IH"'
ok "csv formula prefix" 'grep -q "\"'"'"'<script>\|\"<script>" "$T"/injo/*_servers.csv'
jq '.resources[0].id="=HYPERLINK(1)"' "$HERE/fixtures/rds_compliance_222222222222_20261103.json" >"$T/inj/rds_compliance_222222222222_20261103.json"
run --merge "$T/inj" -o "$T/inj2"; ok "csv = prefixed with '" 'grep -q "\"'"'"'=HYPERLINK" "$T"/inj2/*_servers.csv'

echo "== collector (mock aws, one scan per account)"
export MOCK_NOW=1793700000
export MOCK_LOG="$T/calls"
PATH="$MPATH" run --save-data -P prod,nonprod -A -o "$T/c1"
ok "collect exit 0" '[[ $(rc) == 0 ]]'
ok "one rds_compliance_ACCT_DATE.json per account" '[[ -s "$T/c1/rds_compliance_111111111111_20261103.json" && -s "$T/c1/rds_compliance_222222222222_20261103.json" && $(ls "$T/c1" | wc -l) == 2 ]]'
ok "schema v2 with patch, backup, docdb" 'jq -e ".schema_version==2 and (.patch.rows|length>0) and (.backup.resources|length>0) and (.docdb.resources|length>0)" "$T/c1/rds_compliance_111111111111_20261103.json" >/dev/null'
ok "only read-only calls" '! jq -r ".[0:2]|join(\" \")" "$T/calls" | grep -vE "^(sts get-caller-identity|ec2 describe-regions|rds describe-(db-clusters|db-instances|pending-maintenance-actions|db-cluster-snapshots|db-snapshots|db-engine-versions|db-major-engine-versions|global-clusters)|(docdb|neptune) describe-db-engine-versions|backup list-(backup-vaults|recovery-points-by-backup-vault))$"'
ok "each call once per region (per engine/version/vault)" '[[ -z "$(jq -c "def g(\$f): (index(\$f)) as \$i | if \$i then .[\$i+1] else null end; [g(\"--profile\"), g(\"--region\"), .[0], .[1], g(\"--engine\"), g(\"--engine-version\"), g(\"--backup-vault-name\")]" "$T/calls" | sort | uniq -d)" ]]'
ok "global clusters once per account" '[[ $(jq -r ".[1]" "$T/calls" | grep -c "^describe-global-clusters$") == 2 ]]'
ok "clusters + instances once per region" '[[ $(jq -r ".[1]" "$T/calls" | grep -c "^describe-db-clusters$") == 10 && $(jq -r ".[1]" "$T/calls" | grep -c "^describe-db-instances$") == 10 ]]'
ok "aws_calls in file = calls made" '[[ $(jq -s "map(.aws_calls)|add" "$T"/c1/*.json) == $(wc -l < "$T/calls") ]]'
ok "region lines + summary" 'grep -q "us-east-1: 15 clusters, 35 instances" "$T/err" && grep -q "regions scanned" "$T/err"'
ok "plurals" '! grep -qE "\b1 (clusters|instances|snapshots)\b|\b([02-9]|[0-9]{2,}) (cluster|instance|snapshot),"  "$T/err"'
ok "no sibling-file wording" '! grep -qiE "rds_patch_|rds_backup_|sibling" "$T/err" "$T/out"'
ok "empty regions hidden without -v" '! grep -q "\] eu-west-1:" "$T/err"'
unset MOCK_LOG
PATH="$MPATH" run --save-data -P prod -A -o "$T/c2" -v --parallel 1
ok "-v shows all regions" 'grep -q "\] eu-west-1:" "$T/err"'
ok "--parallel 1 same data" '[[ "$(jq -cS "[.patch.rows, .backup.resources, .docdb.resources]" "$T"/c2/*.json)" == "$(jq -cS "[.patch.rows, .backup.resources, .docdb.resources]" "$T"/c1/rds_compliance_111111111111_20261103.json)" ]]'
run --merge "$T/c1" -o "$T/c1m"
ok "merge v2 files" '[[ $(rc) == 0 ]] && grep -q "inputs: 2 files" "$T/err" && [[ $(tail -n +2 "$T"/c1m/*_servers.csv | wc -l) == 36 ]]'
for sib in patch backup; do
  d="$HERE/../../rds-$sib-compliance"
  if [[ -x "$d/rds_${sib}_compliance_report.sh" ]]; then
    PATH="$MPATH" "$d/rds_${sib}_compliance_report.sh" --save-data -P prod,nonprod -A -o "$T/sib" >/dev/null 2>&1
  fi
done
if ls "$T"/sib/rds_patch_*.json "$T"/sib/rds_backup_*.json >/dev/null 2>&1; then
  ok "parity: patch rows = rds-patch-compliance" '[[ "$(jq -cS -s "map(.rows[])|sort_by(.account,.region,.identifier)" "$T"/sib/rds_patch_*.json)" == "$(jq -cS -s "map(.patch.rows[])|sort_by(.account,.region,.identifier)" "$T"/c1/*.json)" ]]'
  ok "parity: backup resources = rds-backup-compliance" '[[ "$(jq -cS -s "map(.resources[]|del(.arn))|sort_by(.account,.region,.id)" "$T"/sib/rds_backup_*.json)" == "$(jq -cS -s "map(.backup.resources[])|sort_by(.account,.region,.id)" "$T"/c1/*.json)" ]]'
  cp "$T"/c1/*.json "$T/sib/x.json" 2>/dev/null; for f in "$T"/c1/*.json; do jq ".docdb" "$f" >"$T/sib/d_${f##*/}"; done; rm -f "$T/sib/x.json"
  run --merge "$T/sib" -o "$T/sibm"
  ok "parity: servers CSV identical" 'cmp -s "$(ls "$T"/sibm/*_servers.csv)" "$(ls "$T"/c1m/*_servers.csv)"'
else echo "  skip parity (sibling repos not found next to this repo)"; fi
MOCK_SCENARIO=backupdeny PATH="$MPATH" run --save-data -P prod -A -o "$T/c3"
cp "$T"/c3/*.json "$T/bd.json" 2>/dev/null; run --merge "$T/bd.json" -o "$T/c3m"
ok "backup denied -> Unknown or Fail, no crash" '[[ $(rc) == 0 ]] && grep -qE "Unknown|Fail" "$T"/c3m/*_servers.csv'
MOCK_SCENARIO=regionfail PATH="$MPATH" run --save-data -P prod -A -o "$T/c4"
ok "region failure recorded" 'jq -e "[.backup.regions[]?, .patch.region_status[]? | select(.status==\"error\")]|length>0" "$T"/c4/*.json >/dev/null'
MOCK_SCENARIO=empty PATH="$MPATH" run --save-data -P prod -A -o "$T/c5"; ok "empty account ok" '[[ $(rc) == 0 ]]'
PATH="$MPATH" run --save-data -P prod -r us-east-1 --dry-run -o "$T/c6"; ok "dry-run exit 0" '[[ $(rc) == 0 ]]'
PATH="$MPATH" run --save-data -P bogus -r us-east-1 -o "$T/c7"; ok "bad profile -> nonzero, no file" '[[ $(rc) != 0 ]] && ! ls "$T"/c7/*.json >/dev/null 2>&1'

echo "== v1.2.0: compliance exceptions (--exceptions FILE / compliance_exceptions.conf)"
# RDS_CR_NOW 1793700000 = 2026-11-03 (UTC): expiring soon = within 14 days, expires = last valid day
EX="$T/exc"; mkdir -p "$EX"
cat >"$EX/ok.conf" <<'CONF'
# account_id | identifier | scope | expires | reason
111111111111 | reports-pg | patch,backup | 2027-01-31 | Vendor freeze (CHG-9)
111111111111 | legacy-aurora-pg12 | patch | 2026-11-10 | Decommission next week

  111111111111|ORDERS-aurora-pg15|Backup|2027-01-01|Old <i>backup</i> waiver | see CHG-7
111111111111 | hr-sql | patch | 2026-11-02 | =Expired waiver
222222222222 | dev-docdb | backup | 2026-12-31 | Dev DocumentDB, no backups needed
111111111111 | ghost-db | patch | 2027-01-01 | Not there
222222222222 | inv-mysql | patch | 2027-01-01 | Only in account 222
CONF
PATH="$T/fakeaws:$PATH" run --merge "$HERE/fixtures" -o "$EX/on" --exceptions "$EX/ok.conf"
ok "exc: merge exit 0, 0 aws calls" '[[ $(rc) == 0 && ! -e "$T/awscalls" ]]'
XV="$(ls "$EX"/on/*_servers.csv)"; XA="$(ls "$EX"/on/*_accounts.csv)"; XT="$(ls "$EX"/on/*.txt)"; XH="$(ls "$EX"/on/*.html)"; cp "$T/err" "$EX/on.err"
ok "exc: patch 69% (20 of 29, incl. 3), backup 60% (6 of 10, incl. 3)" 'grep -q "^Overall    : 32 server(s), patch 69% (20 of 29, incl. 3 exceptions, 3 no data) | backup 60% (6 of 10, incl. 3 exceptions, 3 not yet due, 19 no data)" "$XT"'
ok "exc: 32 servers, 23 columns" '[[ $(( $(wc -l <"$XV") - 1 )) == 32 ]] && head -1 "$XV" | tr -d "\r" | grep -q ",\"backup_reason\",\"patch_exception\",\"patch_exception_reason\",\"patch_exception_expires\",\"patch_exception_flag\",\"patch_actual_status\",\"backup_exception\",\"backup_exception_reason\",\"backup_exception_expires\",\"backup_exception_flag\",\"backup_actual_status\"$"'
ok "exc: reports-pg both scopes, actual kept" '[[ $(col "$XV" reports-pg 111111111111 6) == "Compliant (exception)" && $(col "$XV" reports-pg 111111111111 11) == "Compliant (exception)" && $(col "$XV" reports-pg 111111111111 17) == Non-compliant && $(col "$XV" reports-pg 111111111111 22) == Fail ]]'
ok "exc: expiring soon (7 days)" '[[ $(col "$XV" legacy-aurora-pg12 111111111111 16) == "expiring soon" && $(col "$XV" legacy-aurora-pg12 111111111111 13) == yes ]]'
ok "exc: Warning -> no longer needed, case-insensitive id + scope, | in reason" '[[ $(col "$XV" orders-aurora-pg15 111111111111 21) == "no longer needed" && $(col "$XV" orders-aurora-pg15 111111111111 22) == Warning && $(col "$XV" orders-aurora-pg15 111111111111 19) == "Old <i>backup</i> waiver | see CHG-7" ]]'
ok "exc: expired = evaluated normally, formula guard" '[[ $(col "$XV" hr-sql 111111111111 6) == Non-compliant && $(col "$XV" hr-sql 111111111111 13) == expired && $(col "$XV" hr-sql 111111111111 14) == "'"'"'=Expired waiver" && $(col "$XV" hr-sql 111111111111 16) == "exception expired" ]]'
ok "exc: scope per account (inv-mysql 222 only)" '[[ $(col "$XV" inv-mysql 222222222222 6) == "Compliant (exception)" && $(col "$XV" inv-mysql 111111111111 6) == Non-compliant && $(col "$XV" inv-mysql 111111111111 13) == no ]]'
ok "exc: patch scope does not touch backup (legacy-aurora-pg12 backup)" '[[ $(col "$XV" legacy-aurora-pg12 111111111111 18) == no && $(col "$XV" legacy-aurora-pg12 111111111111 11) == "No data" ]]'
ok "exc: docdb backup exception (Fail -> OK)" '[[ $(col "$XV" dev-docdb 222222222222 11) == "Compliant (exception)" && $(col "$XV" dev-docdb 222222222222 22) == Fail ]]'
ok "exc: accounts csv exception counts" 'tr -d "\r" <"$XA" | grep -q "\"patch_exceptions\",\"backup_exceptions\"$" && tr -d "\r" <"$XA" | grep -q "^\"111111111111\",.*,\"28\",\"69.2\",.*,\"2\",\"2\"$" && tr -d "\r" <"$XA" | grep -q "^\"222222222222\",.*,\"66.7\",.*,\"100\",.*,\"1\",\"1\"$"'
ok "exc: txt Exceptions section + unmatched" 'grep -q "^Exceptions (3 patch, 3 backup applied; counted as compliant; expiring soon or no longer needed: 2; expired: 1):" "$XT" && grep -q "line 8: 111111111111 ghost-db matched no server" "$XT" && grep -q "hr-sql patch until 2026-11-02, actual Non-compliant, EXPIRED" "$XT"'
ok "exc: log warnings + summary" 'grep -q "WARN.*ok\.conf:8 (111111111111 ghost-db) matched no server" "$EX/on.err" && grep -q "WARN.*(patch) for 111111111111 hr-sql expired on 2026-11-02" "$EX/on.err" && grep -q "Exceptions (patch): 3 applied (counted as compliant), 1 expiring soon or no longer needed, 1 expired, 1 unmatched" "$EX/on.err" && grep -q "Exceptions (backup): 3 applied" "$EX/on.err"'
ok "exc: Not OK list excludes excepted servers" '! sed -n "/^Not OK/,/^Exceptions/p" "$XT" | grep -q " reports-pg \| dev-docdb "'
ok "exc: html escaped, exception data present" '! grep -q "<i>backup</i>" "$XH" && grep -q "\"exc\":{\"patch\"" "$XH"'
ok "exc: no-file run has no exception columns" '! head -1 "$SV" | grep -q exception && ! grep -q "\"exc\":" "$H"'
# validation: strict, file:line, exit 1, before anything is read
xbad() { printf '# header\n111111111111 | good-db | patch | 2027-01-01 | ok\n%s\n' "$3" >"$EX/$1.conf"; run --merge "$HERE/fixtures" -o "$EX/x_$1" --exceptions "$EX/$1.conf"
         ok "exc validation $1: exit 1, $1.conf:3: $2" '[[ $(rc) == 1 ]] && grep -q "Exceptions .*'"$1"'\.conf:3: .*'"$2"'" "$T/err" && [[ ! -e "$EX/x_'"$1"'" || -z "$(ls -A "$EX/x_'"$1"'")" ]]'; }
xbad missing 'missing field' '111111111111 | db1 |  | 2027-01-01 | r'
xbad fields 'expected 5 fields' '111111111111 | db1 | patch'
xbad acct 'account_id must be 12 digits' '123 | db1 | patch | 2027-01-01 | r'
xbad scope 'scope must be patch, backup or patch,backup' '111111111111 | db1 | all | 2027-01-01 | r'
xbad date 'is not a valid date' '111111111111 | db1 | patch | 2026-13-01 | r'
xbad date2 'expires must be a date YYYY-MM-DD' '111111111111 | db1 | patch | soon | r'
xbad glob 'is not a DB instance / cluster identifier' '111111111111 | db% | patch | 2027-01-01 | r'
xbad dup 'duplicate entry for 111111111111 good-DB (patch), already on line 2' '111111111111 | good-DB | backup,patch | 2027-01-01 | r'
run --merge "$HERE/fixtures" -o "$EX/x_nofile" --exceptions "$EX/none.conf"; ok "exc: missing file -> 1" '[[ $(rc) == 1 ]] && grep -q "Exceptions file not readable" "$T/err"'
# default file next to the script (tool copy), config key, --save-data ignores it
TC="$T/toolcopy"; mkdir -p "$TC"; cp -r "$ROOT/rds_compliance_report.sh" "$ROOT/lib" "$TC/"
"$TC/rds_compliance_report.sh" --merge "$HERE/fixtures" -o "$EX/def0" >/dev/null 2>&1
ok "exc default: absent -> off" '! head -1 "$(ls "$EX"/def0/*_servers.csv)" | grep -q exception'
cp "$EX/ok.conf" "$TC/compliance_exceptions.conf"; "$TC/rds_compliance_report.sh" --merge "$HERE/fixtures" -o "$EX/def1" >/dev/null 2>&1
ok "exc default: compliance_exceptions.conf next to the script is used" 'grep -q "incl. 3 exceptions" "$(ls "$EX"/def1/*.txt)"'
printf 'exceptions = %s\n' "$EX/ok.conf" >"$EX/c.conf"; run --config "$EX/c.conf" --merge "$HERE/fixtures" -o "$EX/conf"
ok "exc: config key exceptions = FILE" '[[ $(rc) == 0 ]] && grep -q "incl. 3 exceptions" "$EX"/conf/*.txt'
PATH="$MPATH" run --save-data -P prod -r us-east-1 -o "$EX/sd" --exceptions "$EX/ok.conf"
ok "exc: --save-data warns, file has no exception data" '[[ $(rc) == 0 ]] && grep -q "ignored for --save-data" "$T/err" && ! grep -qi exception "$EX"/sd/*.json'
if command -v node >/dev/null && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && node -e 'require("puppeteer-core")' 2>/dev/null; then
  res="$(node "$HERE/browser_exceptions.js" "$XH" ${SHOTS:+"$SHOTS/exceptions"} 2>&1)"; brc=$?
  echo "  $res"; ok "browser: exception column, quick filter with other filters, pop-ups, CSV" '[[ $brc == 0 ]]'
  res="$(EXPECT='{"servers":32,"patch":"69%","backup":"60%"}' node "$HERE/browser_check.js" "$XH" 2>&1)"; brc=$?
  [[ $brc == 0 ]] || echo "  $res"; ok "browser: existing checks pass on a report with exceptions" '[[ $brc == 0 ]]'
else echo "  skip exceptions browser check (node + puppeteer-core on NODE_PATH + Chrome)"; fi

echo "== shellcheck"
if command -v shellcheck >/dev/null; then ok "shellcheck" 'shellcheck -x "$S" "$HERE/run_tests.sh"'; else echo "  skip shellcheck"; fi

echo "== browser"
if command -v node >/dev/null && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && node -e 'require("puppeteer-core")' 2>/dev/null; then
  res="$(EXPECT='{"servers":32,"patch":"58.6%","backup":"40%"}' node "$HERE/browser_check.js" "$H" ${SHOTS:+"$SHOTS"} 2>&1)"; brc=$?
  echo "  $res"; ok "browser check" '[[ $brc == 0 ]]'
  res="$(EXPECT='{"inject":1}' node "$HERE/browser_check.js" "$IH" 2>&1)"; brc=$?; [[ $brc == 0 ]] || echo "  $res"; ok "browser check (injected id, no alert)" '[[ $brc == 0 ]]'
else echo "  skip browser check (node + puppeteer-core on NODE_PATH + Chrome)"; fi

[[ -n "${KEEP:-}" ]] && cp -r "$T" "$KEEP"
echo; echo "passed $PASS, failed $FAIL"; [[ $FAIL == 0 ]]
