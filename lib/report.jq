# rds_compliance_report.sh - join patch + backup results per server and render (jq 1.6+, Windows jq.exe safe).
# No compliance rule lives here: patch status comes from rds-patch-compliance (lib/patch_merge.jq) and backup status
# from rds-backup-compliance (lib/backup.jq, mode rows). This file only maps them to one row per server and counts.
# Args: $mode (rows|sum|txt|csv|acsv|rcsv|ecsv|html|json); slurped $P (patch merge output), $B (backup.jq rows), $BD / $DD (merged
# backup / DocumentDB+Neptune data docs: accounts, regions); $now, $cfg (backup thresholds + tz), $tool, $page (JS), $page_css.
def utc: if . == null then "" else (floor | todate | sub("T"; " ") | sub(":[0-9]{2}Z$"; " UTC")) end;
def loc: if . == null then "" else ((. + $cfg.tz_offset) | floor | todate | sub("T"; " ") | sub(":[0-9]{2}Z$"; " " + $cfg.tz_label)) end;
def key: "\(.account_id)|\(.region)|\(.identifier)";
def egroup: if . == null then "Unknown"
  elif . == "aurora-postgresql" then "Aurora PostgreSQL" elif . == "aurora-mysql" then "Aurora MySQL"
  elif . == "postgres" then "RDS PostgreSQL" elif . == "mysql" then "RDS MySQL" elif . == "mariadb" then "RDS MariaDB"
  elif startswith("sqlserver") then "RDS SQL Server" elif startswith("oracle") then "RDS Oracle"
  elif . == "docdb" then "DocumentDB" elif . == "neptune" then "Neptune" else . end;
def dn: test("^(docdb|neptune)");
def pmap: {"COMPLIANT": "Compliant", "NON-COMPLIANT": "Non-compliant", "UNKNOWN": "Unknown"}[.] // "Unknown";
$P[0] as $P | $B[0] as $B | $BD[0].accounts as $BA | $DD[0].accounts as $DA
| ([ $P.errors[]? | "\(.account)|\(.region)" ] | unique) as $PE
| ([ ($BD[0].regions + $DD[0].regions)[] | select(.status == "error") | "\(.account)|\(.region)" ] | unique) as $BE
| ($P.rows // []) as $PR | ($B // []) as $BR
| ([ $P.accounts[]?.account ]) as $PAC | ([ $BA[]?.account ]) as $BAC | ([ $DA[]?.account ]) as $DAC
| ([ $PR[] | {key: key, value: .} ] | from_entries) as $PI
| ([ $BR[] | {key: key, value: .} ] | from_entries) as $BI
| def prow($p; $a; $k): if $p == null then
      {patch_status: "No data", patch_reason: (if ($PE | index([$k])) then "patch scan of this region failed" elif ($PAC | index([$a])) then "not in the patch data of this account" else "no patch file for this account" end),
       current_version: null, latest_version: null, versions_behind: null}
    else {patch_status: ($p.compliance_status | pmap), current_version: $p.current_version, latest_version: $p.latest_minor_version,
          versions_behind: $p.versions_behind,
          patch_reason: ([ (if $p.compliance_status == "UNKNOWN" then ($p.note // "" | if . == "" then "version lookup failed or deprecated" else . end) else empty end),
                           (if ($p.pending_actions_count // 0) > 0 then "\($p.pending_actions_count) pending maintenance" else empty end),
                           (if ($p.auto_minor_upgrade | tostring) == "false" then "auto minor upgrade off" else empty end),
                           (if $p.past_standard_support == true then "past standard support" else empty end) ] | join("; "))} end;
  def brow($b; $a; $e; $k): if $b == null then
      {backup_status: "No data", backup_reason: (if ($BE | index([$k])) then "backup scan of this region failed" elif ($e // "" | dn) then (if ($DAC | index([$a])) then "not in the DocumentDB/Neptune data of this account" else "no rds_compliance (DocumentDB/Neptune) file for this account" end)
                                                  else (if ($BAC | index([$a])) then "not in the backup data of this account" else "no backup file for this account" end) end)}
    else ([ ($b.warnings // ""), ($b.retention_mismatch // ""), ($b.excess // "" | if . == "" then "" else "excess: " + . end), ($b.over_retention // "") ] | map(select(. != ""))) as $w
      | if $b.status == "NON-COMPLIANT" then {backup_status: "Fail", backup_reason: $b.gaps}
        elif $b.status == "UNKNOWN" then {backup_status: "Unknown", backup_reason: (if $b.gaps == "" then "a call failed" else $b.gaps end)}
        elif $b.status == "NOT YET DUE" then {backup_status: "Not yet due", backup_reason: $b.not_yet_due}
        elif ($w | length) > 0 then {backup_status: "Warning", backup_reason: ($w | join("; "))}
        else {backup_status: "OK", backup_reason: ""} end end;
  ([ $PR[] | key ] + [ $BR[] | key ] | unique) as $K
| ([ $K[] | . as $k | $PI[$k] as $p | $BI[$k] as $b | ($p // $b) as $x
     | {account_id: $x.account_id, region: $x.region, identifier: $x.identifier, engine: ($p.engine // $b.engine),
        type: ($p.resource_type // ($b.type | if . == "cluster" then "cluster" else "instance" end))}
     | . + {engine_group: (.engine | egroup)} + prow($p; .account_id; "\(.account_id)|\(.region)") + brow($b; .account_id; .engine; "\(.account_id)|\(.region)") ]
   | sort_by(.account_id, .region, .engine_group, .identifier)) as $S
# percentages exactly as each tool: patch = compliant / servers with patch data (1 decimal, rds-patch-compliance);
# backup = (OK + Warning) / (servers with backup data - not yet due) (whole %, rds-backup-compliance)
| def tot: {servers: length,
      patch_data: (map(select(.patch_status != "No data")) | length), patch_ok: (map(select(.patch_status == "Compliant")) | length),
      patch_fail: (map(select(.patch_status == "Non-compliant")) | length), patch_unknown: (map(select(.patch_status == "Unknown")) | length),
      patch_nodata: (map(select(.patch_status == "No data")) | length),
      backup_ok: (map(select(.backup_status == "OK")) | length), backup_warn: (map(select(.backup_status == "Warning")) | length),
      backup_fail: (map(select(.backup_status == "Fail")) | length), backup_unknown: (map(select(.backup_status == "Unknown")) | length),
      backup_nyd: (map(select(.backup_status == "Not yet due")) | length), backup_nodata: (map(select(.backup_status == "No data")) | length)}
    | . + {patch_pct: (if .patch_data == 0 then null else ((.patch_ok * 1000 / .patch_data | round) / 10) end),
           backup_due: (.servers - .backup_nodata - .backup_nyd)}
    | . + {backup_pct: (if .backup_due == 0 then null else (100 * (.backup_ok + .backup_warn) / .backup_due | round) end)};
  def pcts: if . == null then "-" else "\(.)%" end;
  def grp(f): group_by(f) | map({k: (.[0] | f), t: tot});
  ($S | tot) as $T
| ([ ($PAC + $BAC + $DAC + [ $S[].account_id ] | unique)[] | . as $a
     | {account_id: $a,
        patch_collected: ([ $P.accounts[]? | select(.account == $a) | .collected_epoch ] | first),
        backup_collected: ([ $BA[]? | select(.account == $a) | .collected_epoch ] | first),
        docdb_collected: ([ $DA[]? | select(.account == $a) | .collected_epoch ] | first),
        t: ([ $S[] | select(.account_id == $a) ] | tot)} ]) as $AC
| ($S | grp(.account_id + "|" + .region)) as $RG
| ($S | grp(.engine_group)) as $EG
| def srowcols: ["account_id","region","engine","engine_group","type","identifier","patch_status","current_version","latest_version",
                 "versions_behind","patch_note","backup_status","backup_reason"];
  def csvrow: map(if . == null then "" elif type == "string" then (if test("^[=+@\\-\t\r]") then "'" + . else . end
                   | if test("^[0-9]+(\\.[0-9]+)+$") then "=\"" + . + "\"" else . end) else tostring end) | @csv;
  def scsv($r): [$r.account_id, $r.region, $r.engine, $r.engine_group, $r.type, $r.identifier, $r.patch_status, $r.current_version,
                 $r.latest_version, $r.versions_behind, $r.patch_reason, $r.backup_status, $r.backup_reason];
  def tcols: ["servers","patch_pct","patch_compliant","patch_non_compliant","patch_unknown","patch_no_data",
              "backup_pct","backup_ok","backup_warning","backup_fail","backup_unknown","backup_not_yet_due","backup_no_data"];
  def tvals($t): [$t.servers, $t.patch_pct, $t.patch_ok, $t.patch_fail, $t.patch_unknown, $t.patch_nodata,
                  $t.backup_pct, $t.backup_ok, $t.backup_warn, $t.backup_fail, $t.backup_unknown, $t.backup_nyd, $t.backup_nodata];
  def ttxt($t): "patch \($t.patch_pct | pcts) (\($t.patch_ok) of \($t.patch_data)\(if $t.patch_nodata > 0 then ", \($t.patch_nodata) no data" else "" end))"
     + " | backup \($t.backup_pct | pcts) (\($t.backup_ok + $t.backup_warn) of \($t.backup_due)\(if $t.backup_warn > 0 then ", \($t.backup_warn) warning" else "" end)"
     + "\(if $t.backup_nyd > 0 then ", \($t.backup_nyd) not yet due" else "" end)\(if $t.backup_nodata > 0 then ", \($t.backup_nodata) no data" else "" end))";
  def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;
  def colt($e): if $e == null then "-" else "\($e | utc) / \($e | loc)" end;
  {max_behind: $P.max_behind, oracle_any_patch_line: ($P.oracle_any_patch_line // false)} as $PC
| if $mode == "rows" then $S
  elif $mode == "csv" then (srowcols | csvrow), ($S[] | scsv(.) | csvrow)
  elif $mode == "acsv" then (["account_id","patch_collected_utc","backup_collected_utc","docdb_neptune_collected_utc"] + tcols | csvrow),
       ($AC[] | [.account_id, (.patch_collected | utc), (.backup_collected | utc), (.docdb_collected | utc)] + tvals(.t) | csvrow)
  elif $mode == "rcsv" then (["account_id","region"] + tcols | csvrow), ($RG[] | (.k | split("|")) + tvals(.t) | csvrow)
  elif $mode == "ecsv" then (["engine"] + tcols | csvrow), ($EG[] | [.k] + tvals(.t) | csvrow)
  elif $mode == "json" then {tool: "rds_compliance_report", version: $tool, generated_utc: ($now | utc), generated_local: ($now | loc), totals: $T,
                             accounts: $AC, regions: $RG, engines: $EG, servers: $S}
  elif $mode == "sum" then "\($S | length) server(s): " + ttxt($T)
  elif $mode == "txt" then
    "RDS compliance report v\($tool) - generated \($now | utc) / \($now | loc)",
    "Patch rule : rds-patch-compliance, COMPLIANT when at most \($PC.max_behind) minor version(s) behind\(if $PC.oracle_any_patch_line then " (Oracle: any patch line)" else "" end); UNKNOWN counts in the %",
    "Backup rule: rds-backup-compliance, daily \($cfg.daily) automated (\($cfg.daily_retention_days)d) / weekly \(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][$cfg.weekly_weekday]) \($cfg.weekly_retention_days)d / monthly first \(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][$cfg.monthly_weekday]) x\($cfg.monthly) \($cfg.monthly_retention_days)d; warnings count as compliant; not yet due excluded",
    "",
    "Overall    : \($S | length) server(s), " + ttxt($T),
    "",
    "Accounts:",
    ($AC[] | "  \(.account_id)  \(.t.servers) server(s)  " + ttxt(.t),
             "    collected: patch \(colt(.patch_collected)); backup \(colt(.backup_collected)); DocumentDB/Neptune \(colt(.docdb_collected))"),
    "",
    "Regions:",
    ($RG[] | "  \(.k | sub("\\|"; " ") | pad(28)) \(.t.servers | tostring | pad(4)) " + ttxt(.t)),
    "",
    "Engines:",
    ($EG[] | "  \(.k | pad(18)) \(.t.servers | tostring | pad(4)) " + ttxt(.t)),
    "",
    "Not OK (patch non-compliant / unknown, backup fail / warning / unknown):",
    ([ $S[] | select(.patch_status == "Non-compliant" or .patch_status == "Unknown" or .backup_status == "Fail" or .backup_status == "Warning" or .backup_status == "Unknown") ]
     | if length == 0 then "  none" else .[] | "  \(.account_id) \(.region) \(.identifier) [\(.engine_group)]: patch \(.patch_status)"
        + (if .versions_behind != null then " (\(.current_version) -> \(.latest_version), \(.versions_behind) behind)" else "" end)
        + (if .patch_reason != "" then " [\(.patch_reason)]" else "" end)
        + "; backup \(.backup_status)" + (if .backup_reason != "" then " (\(.backup_reason))" else "" end) end)
  elif $mode == "html" then
    ({generated: "\($now | utc) / \($now | loc)", tool: $tool, tz: $cfg.tz_label,
      rules: {max_behind: $PC.max_behind, oracle_any: $PC.oracle_any_patch_line, daily: $cfg.daily, daily_ret: $cfg.daily_retention_days,
              weekly_day: (["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][$cfg.weekly_weekday]), weekly_ret: $cfg.weekly_retention_days,
              monthly_day: (["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][$cfg.monthly_weekday]), monthly: $cfg.monthly, monthly_ret: $cfg.monthly_retention_days},
      accounts: [ $AC[] | {a: .account_id, p: (.patch_collected | if . == null then null else "\(utc) / \(loc)" end),
                                           b: (.backup_collected | if . == null then null else "\(utc) / \(loc)" end),
                                           d: (.docdb_collected | if . == null then null else "\(utc) / \(loc)" end)} ],
      cols: srowcols, rows: $S, stamp: ($now | todate | gsub("[-:]"; "") | sub("T"; "_") | sub("Z"; "")),
      acct: (if ($AC | length) == 1 then $AC[0].account_id else "" end)} | tojson
     | gsub("<"; "\\u003c") | gsub(">"; "\\u003e") | gsub("&"; "\\u0026")) as $J
    | "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      + "<title>RDS compliance report</title><style>" + $page_css + "</style></head><body><div id=\"app\"></div>"
      + "<script id=\"data\" type=\"application/json\">" + $J + "</script><script>" + $page + "</script></body></html>"
  else error("unknown mode \($mode)") end
