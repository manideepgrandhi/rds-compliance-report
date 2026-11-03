# rds-compliance-report

One offline HTML report of **patch** and **backup** compliance for AWS RDS, Aurora, DocumentDB and Neptune, per account, region, engine and server.
It joins the saved data of [rds-patch-compliance](https://github.com/manideepgrandhi/rds-patch-compliance) and
[rds-backup-compliance](https://github.com/manideepgrandhi/rds-backup-compliance) (v1.5.1+) and adds a small read-only collector for DocumentDB / Neptune backups.
The rules are the ones in those tools, unchanged (their jq is copied into `lib/`). Parameter drift and DynamoDB are out of scope.

## Install (CloudShell, Linux, macOS, Git Bash)

```bash
curl -fsSLO https://github.com/manideepgrandhi/rds-compliance-report/releases/latest/download/rds-compliance-report.zip
curl -fsSLO https://github.com/manideepgrandhi/rds-compliance-report/releases/latest/download/rds-compliance-report.zip.sha256
sha256sum -c rds-compliance-report.zip.sha256 && unzip -oq rds-compliance-report.zip && cd rds-compliance-report
./rds_compliance_report.sh --version
```

Needs bash 4+, jq 1.6+; the collector also needs AWS CLI v2. Merge makes **0 AWS calls**.

## 1. Collect (CloudShell, each account)

```bash
./rds_patch_compliance_report.sh  --save-data -A          # rds-patch-compliance  -> rds_patch_<ACCT>_<DATE>.json
./rds_backup_compliance_report.sh --save-data -A          # rds-backup-compliance -> rds_backup_<ACCT>_<DATE>.json
./rds_compliance_report.sh        --save-data -A          # this tool (DocumentDB/Neptune) -> rds_compliance_<ACCT>_<DATE>.json
```

The collector is read-only and calls only: `sts get-caller-identity`, `ec2 describe-regions`, `rds describe-db-clusters`,
`rds describe-db-cluster-snapshots` (both filtered to engine docdb,neptune), `backup list-backup-vaults`, `backup list-recovery-points-by-backup-vault`.
Regions run `--parallel N` at a time (default 4). The console prints one line per region with clusters and a summary per account; `-v` lists every region.

## 2. Merge (anywhere, offline)

```bash
./rds_compliance_report.sh --merge ./data -o ./reports            # files and/or folders, any number
```

Per account and source (patch / backup / docdb) the newest `collected_at` wins; older files are logged and ignored.
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

**No data**: a server missing from one source shows "No data" with the reason (region scan failed, no file for this account, not in that account's data).
It is never counted as compliant and is left out of that %.

Engines: Aurora PostgreSQL / MySQL, RDS PostgreSQL, MySQL, MariaDB, SQL Server, Oracle, Multi-AZ DB clusters, DocumentDB, Neptune.
DocumentDB / Neptune backup status comes only from `rds_compliance_*.json`.

## Options

Run `./rds_compliance_report.sh --help`. Every long option can go in a `--config` file (see `rds_compliance_report.conf.example`).
Exit codes: 0 ok, 1 usage, 2 pre-check, 3 bad `--merge` input, 4 output error.

## Limitations

- DocumentDB global clusters: only the secondary's `ReplicationSourceIdentifier` is seen; global membership is not resolved.
- DocumentDB / Neptune patch status is whatever rds-patch-compliance saved for them.
- Excel may still reformat other values on manual edits; the CSV is written to avoid date conversion of versions.

## Tests

```bash
NODE_PATH=/path/to/node_modules bash tests/run_tests.sh   # mock aws + fixtures, shellcheck, headless Chrome (puppeteer-core) if present
```

See [EXAMPLES.md](EXAMPLES.md). MIT license.
