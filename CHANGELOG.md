# Changelog

Plain-English features for each published release. The What's new page is built from this file.

## 1.1.0
- One script does both steps: `--save-data` per account, then offline `--merge` with 0 AWS calls
- Combined patch and backup compliance in one HTML report (cards, filters, account / region / engine tables)
- Shared collector makes each region call once for both checks
- CSV exports for servers, accounts, regions and engines; times shown in UTC and IST

## 1.0.0
- First release: offline combined patch and backup compliance report
- Rules match rds-patch-compliance and rds-backup-compliance
- HTML, text and CSV output from saved account data files
