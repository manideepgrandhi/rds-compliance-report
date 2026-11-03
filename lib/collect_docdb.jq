# rds_compliance_report.sh --save-data: DocumentDB / Neptune clusters of one account + region, in the resource
# shape of rds-backup-compliance (lib/collect.jq), so lib/backup.jq evaluates them with the same rules.
# Adapted from rds-backup-compliance v1.5.1 lib/collect.jq (cluster part only, engine filter inverted).
# Args: $acct, $region, $clusters, $csnaps, $rps (slurped files), $csnap_ok, $backup_ok.
def ts: if . == null or . == "" then null elif type == "number" then floor
  else capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
    | ($m.d + "Z" | fromdateiso8601) as $e
    | if ($m.z // "Z") == "Z" then $e
      else ($m.z | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")) as $o
        | (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60) as $sec | if $o.s == "+" then $e - $sec else $e + $sec end end end;
def in_scope: test("^(docdb|neptune)");
($rps[0] // []) as $RP
| def rps($arn): ($arn | ascii_downcase) as $la | [ $RP[] | select((.ResourceArn // "" | ascii_downcase) == $la)
      | {kind: "backup", id: (.RecoveryPointArn | split(":") | last), created_epoch: (.CreationDate | ts), status: .Status,
         size_gb: (if .BackupSizeInBytes == null then null else ((.BackupSizeInBytes / 1073741824 * 10 | round) / 10) end),
         expires_epoch: (.CalculatedLifecycle.DeleteAt | ts), vault: .BackupVaultName}
      + (if .Lifecycle.DeleteAfterDays != null then {ret_days: .Lifecycle.DeleteAfterDays} else {} end)
      + (if (.RecoveryPointArn // "" | test(":continuous:")) or .BackupType == "CONTINUOUS" then {continuous: true} else {} end)
      + ((.CreatedBy // {}) | {plan: (.BackupPlanName // .BackupPlanId // null), rule: (.BackupRuleName // .BackupRuleId // null),
                               cron: (.BackupRuleCron // null), rtz: (.BackupRuleTimezone // null)} | with_entries(select(.value != null))) ];
  [ ($clusters[0].DBClusters // [])[] | select((.Engine // "") | in_scope) | . as $c
    | {account_id: $acct, region: $region, id: .DBClusterIdentifier, type: "cluster", engine: .Engine, engine_version: .EngineVersion,
       created_epoch: (.ClusterCreateTime | ts), retention: (.BackupRetentionPeriod // 0),
       backup_window: (.PreferredBackupWindow // null), copy_tags: (if .CopyTagsToSnapshot == null then null else .CopyTagsToSnapshot end),
       global_cluster: null,
       global_role: (if (.ReplicationSourceIdentifier // "") != "" then "replica" else "none" end),
       snap_ok: $csnap_ok, backup_ok: $backup_ok,
       snapshots: ([ ($csnaps[0].DBClusterSnapshots // [])[] | select(.DBClusterIdentifier == $c.DBClusterIdentifier and (.SnapshotType == "manual" or .SnapshotType == "automated"))
                     | {kind: .SnapshotType, id: .DBClusterSnapshotIdentifier, created_epoch: (.SnapshotCreateTime | ts), status: .Status,
                        size_gb: .AllocatedStorage, expires_epoch: null} ] + rps($c.DBClusterArn))} ]
