# rds-compliance-report

One offline HTML report of **patch** and **backup** compliance for AWS RDS, Aurora, Multi-AZ DB clusters, DocumentDB and Neptune, per account, region, engine and server.
**One script, two steps:** `--save-data` scans each account once (read-only) and writes one file; `--merge` builds the report from those files with 0 AWS calls.
The rules are the ones in [rds-patch-compliance](https://github.com/manideepgrandhi/rds-patch-compliance) and
[rds-backup-compliance](https://github.com/manideepgrandhi/rds-backup-compliance), unchanged: their jq (collection and evaluation) is copied into `lib/`, so results are identical. Parameter drift and DynamoDB are out of scope.

## Install (CloudShell, Linux, macOS, Git Bash)

```bash
curl -fsSLO https://github.com/manideepgrandhi/rds-compliance-report/releases/latest/download/rds-compliance-report.zip
curl -fsSLO https://github.com/manideepgrandhi/rds-compliance-report/releases/latest/download/rds-compliance-report.zip.sha256
sha256sum -c rds-compliance-report.zip.sha256 && unzip -oq rds-compliance-report.zip && cd rds-compliance-report
./rds_compliance_report.sh --version
```

Needs bash 4+, jq 1.6+; the collector also needs AWS CLI v2. Merge makes **0 AWS calls**.

## 1. Collect (CloudShell, once per account)

```bash
./rds_compliance_report.sh --save-data -A                 # -> rds_compliance_<ACCOUNT>_<YYYYMMDD>.json (one file per account)
```

`-P prof1,prof2` scans several accounts (one file each); `-r us-east-1,ap-south-1` instead of `-A` limits regions; `--parallel N` regions at a time (default 4); `-o DIR`; `-v` lists every region.
Running the script with no arguments prints the usage.

Read-only. Every call is made once per region (the cluster and instance lists are shared by the patch and backup checks):

| scope | calls |
|---|---|
| account | `sts get-caller-identity`, `ec2 describe-regions` (`-A`), `rds describe-global-clusters` (once, only if there are Aurora clusters) |
| region | `rds describe-db-clusters`, `describe-db-instances`; when the region has databases also `describe-pending-maintenance-actions`, `describe-db-cluster-snapshots` and `describe-db-snapshots` (`--include-shared`), `backup list-backup-vaults`, `list-recovery-points-by-backup-vault` (per vault) |
| per engine | `describe-db-engine-versions` (per engine + version in use; docdb / neptune through their own CLI service), `describe-db-major-engine-versions` (per RDS engine) |

The console prints one line per region (`[4/5] us-east-1: 15 clusters, 35 instances, 83 snapshots, 95 recovery points (2s)`), then per account
`5 regions scanned, …` and `patch N servers, backup X RDS/Aurora + Y DocumentDB/Neptune, C AWS calls`. Times are UTC + IST; full output paths are printed.
Regions with no clusters or instances get no further calls, so orphaned snapshots there are not collected (orphans are not part of the report).

## 2. Merge (anywhere, offline)

```bash
./rds_compliance_report.sh --merge ./data -o ./reports            # files and/or folders, any number
```

Inputs are `rds_compliance_*.json`. Per account the newest collection wins; older files are logged and ignored.
Output (account number in the name when there is one account, else `N_accounts`):

| file | content |
|---|---|
| `<prefix>_<acct>_<stamp>.html` | single offline file: cards, filters (account, region, engine, status, search, Reset), account / region / engine tables, servers table, Export CSV of the filtered rows |
| `.txt` | summary + every server that is not OK (also printed) |
| `_servers.csv` `_accounts.csv` `_regions.csv` `_engines.csv` | RFC 4180, UTF-8 BOM, CRLF; formula cells prefixed with `'`; versions like 15.10 written as `="15.10"` so Excel keeps them |

Full paths are printed; times are UTC + IST (`--tz`).

## Rules

**Patch** (rds-patch-compliance): more than `--max-behind` (default 2) minor versions behind the newest = Non-compliant; deprecated / unknown version = Unknown (counted in the %).
`--oracle-any-patch-line` as in that tool. Patch % = compliant / servers with patch data.

**Backup** (rds-backup-compliance `backup.jq`): daily / weekly / monthly / yearly checks. Retention mismatch, excess backups and over-retention are **Warning** (counts as compliant).
Fail, Unknown, Not yet due (new resource; left out of the %), OK. Backup % = (OK + Warning) / (servers − no data − not yet due).

**No data**: a server missing from one source shows "No data" with the reason (region scan failed, no data for this account, not in that account's data).
It is never counted as compliant and is left out of that %.

Engines: Aurora PostgreSQL / MySQL, RDS PostgreSQL, MySQL, MariaDB, SQL Server, Oracle, Multi-AZ DB clusters, DocumentDB, Neptune.

## Options

Run `./rds_compliance_report.sh --help`. Every long option can go in a `--config` file (see `rds_compliance_report.conf.example`).
Exit codes: 0 ok, 1 usage, 2 pre-check, 3 bad `--merge` input, 4 output error.

## Limitations

- DocumentDB global clusters: only the secondary's `ReplicationSourceIdentifier` is seen; global membership is not resolved.
- Regions without databases are not scanned for orphaned snapshots.
- Excel may still reformat other values on manual edits; the CSV is written to avoid date conversion of versions.

## Tests

```bash
NODE_PATH=/path/to/node_modules bash tests/run_tests.sh   # mock aws + fixtures, once-per-region call check, parity with
                                                          # ../rds-patch-compliance and ../rds-backup-compliance if present, shellcheck, headless Chrome
```

See [EXAMPLES.md](EXAMPLES.md). MIT license.
