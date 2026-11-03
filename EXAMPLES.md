# Examples

```bash
# CloudShell, one account, all regions: the three collectors
./rds_patch_compliance_report.sh  --save-data -A
./rds_backup_compliance_report.sh --save-data -A
./rds_compliance_report.sh        --save-data -A                 # DocumentDB / Neptune
./rds_compliance_report.sh        --save-data -P prod,dev -r us-east-1,ap-south-1 --parallel 2 -v

# merge everything downloaded from several accounts (Git Bash / Linux / macOS, 0 AWS calls)
./rds_compliance_report.sh --merge ~/Downloads/rds_*.json -o ./reports
./rds_compliance_report.sh --merge ./prod ./dev -o ./reports --max-behind 1
./rds_compliance_report.sh --merge ./data -o ./reports --oracle-any-patch-line --monthly 6
./rds_compliance_report.sh --merge ./data -o ./reports --config my.conf --prefix q4_compliance
```

Example console (merge of `tests/fixtures`):

```
[WARN] patch, account 111111111111: rds_patch_111111111111_20261027.json ignored, rds_patch_111111111111_20261103.json is newer
Overall    : 32 server(s), patch 58.6% (17 of 29, 3 no data) | backup 40% (4 of 10, 1 warning, 3 not yet due, 19 no data)
  111111111111  28 server(s)  patch 61.5% (16 of 26, 2 no data) | backup 44% (4 of 9, 1 warning, 3 not yet due, 16 no data)
  222222222222  4 server(s)  patch 33.3% (1 of 3, 1 no data) | backup 0% (0 of 1, 3 no data)
```
