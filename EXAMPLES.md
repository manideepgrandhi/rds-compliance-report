# Examples

```bash
# CloudShell, one account, all regions -> rds_compliance_<ACCOUNT>_<YYYYMMDD>.json
./rds_compliance_report.sh --save-data -A
# two accounts, two regions, 2 regions at a time, every region listed
./rds_compliance_report.sh --save-data -P prod,nonprod -r us-east-1,ap-south-1 --parallel 2 -v -o ./data

# merge the files downloaded from several accounts (Git Bash / Linux / macOS, 0 AWS calls)
./rds_compliance_report.sh --merge ~/Downloads/rds_compliance_*.json -o ./reports
./rds_compliance_report.sh --merge ./prod ./nonprod -o ./reports --max-behind 1
./rds_compliance_report.sh --merge ./data -o ./reports --oracle-any-patch-line --monthly 6
./rds_compliance_report.sh --merge ./data -o ./reports --config my.conf --prefix q4_compliance
```

Example collect console (mock account, `-P prod -A`):

```
[INFO] rds_compliance_report.sh 1.1.0 started 2026-11-03 10:00:00 UTC / 2026-11-03 15:30:00 IST
[INFO] 111111111111 (prod): scanning 5 regions for patch + backup data, up to 4 at a time
[WARN] us-east-1: aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
[INFO] [5/5] us-west-2: 3 clusters, 2 instances, 20 snapshots, 0 recovery points (1s)
[INFO] [4/5] us-east-1: 15 clusters, 35 instances, 83 snapshots, 95 recovery points (2s)
[INFO] 111111111111: 5 regions scanned, 18 clusters, 37 instances, 3 empty: ap-south-1, ca-central-1, eu-west-1
[INFO] 111111111111: patch 29 servers, backup 25 RDS/Aurora + 5 DocumentDB/Neptune, 59 AWS calls
[INFO] AWS calls: 59 (0 failed)
Output (1 file):
  /home/cloudshell-user/rds_compliance_111111111111_20261103.json
```

Example merge console (two mock accounts):

```
[INFO] inputs: 2 files
Overall    : 36 server(s), patch 57.1% (20 of 35, 1 no data) | backup 15% (5 of 33, 2 warning, 3 not yet due)
  111111111111  30 server(s)  patch 51.7% (15 of 29, 1 no data) | backup 15% (4 of 27, 1 warning, 3 not yet due)
  222222222222  6 server(s)  patch 83.3% (5 of 6) | backup 17% (1 of 6, 1 warning)
```


## Exceptions (v1.2.0)

Approved exceptions for servers you know are non-compliant. Same shared file as rds-patch-compliance and rds-backup-compliance. Patch and backup scopes apply independently at `--merge`. Matched, unexpired entries show as **Compliant (exception)**, count as compliant in every %, and appear on the cards as `incl. X exceptions`. The HTML gets an Exception column and an exceptions quick filter. Flags: **expiring soon** (14 days or less), **no longer needed**, **exception expired**. **No data stays No data**: an exception for a server with no data in that source is not applied (shown as "no data, not applied", with a log warning). With no file the reports are exactly as before. `--save-data` files never change; `--exceptions` is ignored with `--save-data`.

### 1. Set up the file

```bash
cp /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf.example \
   /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf
vi /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf
```

One entry per line, all five fields required (`account_id | identifier | scope | expires | reason`). Sample:

```text
# account_id | identifier         | scope        | expires    | reason
111111111111 | legacy-aurora-pg12 | patch        | 2026-12-31 | Decommission in December, CHG-1234 (owner: dba-team)
111111111111 | reports-pg         | patch,backup | 2027-03-31 | Vendor-pinned version, backups by vendor tool | INC-77
111111111111 | dev-docdb          | backup       | 2027-01-31 | Dev DocumentDB, data rebuilt from source
```

`expires` is mandatory `YYYY-MM-DD` (UTC), last day the exception applies. `#` comments and blank lines are ignored. The real `compliance_exceptions.conf` is in `.gitignore`.

### 2. Default run (file next to the script, at `--merge`)

If `compliance_exceptions.conf` sits next to the script it is picked up automatically when you build the report:

```bash
/home/cloudshell-user/rds-compliance-report/rds_compliance_report.sh \
  --merge /home/cloudshell-user/data -o /home/cloudshell-user/reports
```

### 3. Custom location

```bash
mkdir -p /home/cloudshell-user/configs
cp /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf.example \
   /home/cloudshell-user/configs/compliance_exceptions.conf
# edit /home/cloudshell-user/configs/compliance_exceptions.conf, then:
/home/cloudshell-user/rds-compliance-report/rds_compliance_report.sh \
  --merge /home/cloudshell-user/data -o /home/cloudshell-user/reports \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

Config file alternative: `exceptions = /home/cloudshell-user/configs/compliance_exceptions.conf` (CLI `--exceptions` wins).

### 4. Multi-account: `--save-data` then `--merge`

Exceptions are applied only at `--merge`. With `--save-data`, `--exceptions` is ignored (saved JSON has no exception data).

```bash
# CloudShell, once per account (read-only) -> rds_compliance_<ACCOUNT>_<YYYYMMDD>.json
# --exceptions here is ignored (warns and continues)
/home/cloudshell-user/rds-compliance-report/rds_compliance_report.sh --save-data -A \
  -o /home/cloudshell-user/data \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

Real captured warning:

```text
2026-11-09 16:08:06 [WARN] --exceptions is used with --merge (report time); ignored for --save-data
```

Then merge with exceptions:

```bash
/home/cloudshell-user/rds-compliance-report/rds_compliance_report.sh \
  --merge /home/cloudshell-user/data -o /home/cloudshell-user/reports \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

### 5. Validation error (run stops, exit 1, before any merge work)

A missing field, a bad account / scope / date, or a duplicate account + identifier for the same scope stops the run with `file:line`. Real captured output:

Invalid date (month 13):

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf:3: expires '2026-13-01' is not a valid date
```

Duplicate (case-insensitive identifier; `backup,patch` collides with an existing `patch` row):

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf:3: duplicate entry for 111111111111 good-DB (patch), already on line 2
```

Fix: correct the date to a real `YYYY-MM-DD`, or remove / change the duplicate line so each account + identifier appears at most once per scope (`patch` and `backup` may both be listed, either as two lines or as `patch,backup`).

### 6. Turning exceptions off

```bash
# rename (keep for later)
mv /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf \
   /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf.off

# or remove
rm /home/cloudshell-user/rds-compliance-report/compliance_exceptions.conf
```

With no file (and no `--exceptions`), the report matches the pre-exceptions behaviour.
