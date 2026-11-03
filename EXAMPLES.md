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
