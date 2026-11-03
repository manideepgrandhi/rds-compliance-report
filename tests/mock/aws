#!/usr/bin/env python3
# Mock aws CLI for the DocumentDB / Neptune collector tests. Data is relative to MOCK_NOW (epoch, default: now).
# MOCK_LOG=file appends every call; MOCK_SCENARIO: fleet (default) | empty | backupdeny | regionfail
import json, os, sys
from datetime import datetime, timedelta, timezone

a = sys.argv[1:]
NOW = datetime.fromtimestamp(int(os.environ.get("MOCK_NOW") or datetime.now(timezone.utc).timestamp()), timezone.utc)
SCEN = os.environ.get("MOCK_SCENARIO", "fleet")
if os.environ.get("MOCK_LOG"):
    with open(os.environ["MOCK_LOG"], "a") as f:
        f.write(" ".join(a) + "\n")


def opt(name, default=None):
    return a[a.index(name) + 1] if name in a else default


svc, op = (a + ["", ""])[0:2]
region = opt("--region", "us-east-1")
prof = opt("--profile", "default")
acct = {"prod": "111111111111", "dev": "222222222222"}.get(prof, "111111111111")


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def fail(code, opn, msg):
    sys.stderr.write("\nAn error occurred (%s) when calling the %s operation: %s\n" % (code, opn, msg)); sys.exit(254)


# id, engine, version, region, age days, retention, weekly?, monthly?, replica source
FLEET = {"111111111111": [
    ("catalog-docdb", "docdb", "5.0.0", "us-east-1", 900, 7, True, True, None),
    ("graph-neptune", "neptune", "1.3.2.1", "us-east-1", 900, 1, False, False, None),
    ("new-docdb", "docdb", "5.0.0", "us-east-1", 2, 7, False, False, None),
    ("catalog-docdb-dr", "docdb", "5.0.0", "us-west-2", 400, 7, False, False, "arn:aws:rds:us-east-1:111111111111:cluster:catalog-docdb"),
], "222222222222": [("dev-docdb", "docdb", "4.0.0", "ap-south-1", 500, 7, True, False, None)]}
rows = [] if SCEN == "empty" else [r for r in FLEET[acct] if r[3] == region]
if SCEN == "regionfail" and region == "us-west-2" and svc == "rds":
    fail("AccessDenied", "DescribeDBClusters", "User is not authorized to perform: rds:DescribeDBClusters")


def arn(r):
    return "arn:aws:rds:%s:%s:cluster:%s" % (r[3], acct, r[0])


def created(r):
    return (NOW - timedelta(days=r[4])).replace(hour=0, minute=0, second=0, microsecond=0)


def saturdays(n):
    d = NOW.replace(hour=5, minute=0, second=0, microsecond=0) - timedelta(days=(NOW.weekday() - 5) % 7)
    if d > NOW: d -= timedelta(days=7)
    return [d - timedelta(days=7 * k) for k in range(n)]


def first_sundays(n):
    out, y, m = [], NOW.year, NOW.month
    while len(out) < n:
        d = datetime(y, m, 1, 4, 0, tzinfo=timezone.utc)
        d += timedelta(days=(6 - d.weekday()) % 7)
        if d <= NOW: out.append(d)
        y, m = (y, m - 1) if m > 1 else (y - 1, 12)
    return out


if svc == "sts":
    print(json.dumps({"Account": acct, "Arn": "arn:aws:iam::%s:user/mock" % acct})); sys.exit(0)
if svc == "ec2" and op == "describe-regions":
    print(json.dumps({"Regions": [{"RegionName": r} for r in ["us-east-1", "us-west-2", "ap-south-1", "eu-west-1"]]})); sys.exit(0)
if svc == "rds" and op == "describe-db-clusters":
    out = [{"DBClusterIdentifier": r[0], "DBClusterArn": arn(r), "Engine": r[1], "EngineVersion": r[2], "Status": "available",
            "BackupRetentionPeriod": r[5], "ClusterCreateTime": iso(created(r)), "PreferredBackupWindow": "03:00-03:30",
            "CopyTagsToSnapshot": True, **({"ReplicationSourceIdentifier": r[8]} if r[8] else {})} for r in rows]
    if region == "us-east-1" and rows:   # Aurora must be ignored by the collector (rds-backup-compliance covers it)
        out.append({"DBClusterIdentifier": "orders-aurora-pg15", "DBClusterArn": "arn:aws:rds:us-east-1:%s:cluster:orders-aurora-pg15" % acct,
                    "Engine": "aurora-postgresql", "EngineVersion": "15.8", "BackupRetentionPeriod": 7, "ClusterCreateTime": iso(NOW)})
    print(json.dumps({"DBClusters": out})); sys.exit(0)
if svc == "rds" and op == "describe-db-cluster-snapshots":
    out = []
    for r in rows:
        for k in range(r[5]):
            t = NOW - timedelta(hours=2 + 24 * k)
            if t < created(r): break
            out.append({"DBClusterIdentifier": r[0], "DBClusterSnapshotIdentifier": "rds:%s-%s" % (r[0], t.strftime("%Y-%m-%d-%H-%M")),
                        "SnapshotType": "automated", "SnapshotCreateTime": iso(t), "Status": "available", "AllocatedStorage": 0, "Engine": r[1]})
    print(json.dumps({"DBClusterSnapshots": out})); sys.exit(0)
if svc == "backup" and op == "list-backup-vaults":
    if SCEN == "backupdeny":
        fail("AccessDeniedException", "ListBackupVaults", "User is not authorized to perform: backup:ListBackupVaults")
    print(json.dumps({"BackupVaultList": [{"BackupVaultName": n} for n in ["Default", "prod vault"]]})); sys.exit(0)
if svc == "backup" and op == "list-recovery-points-by-backup-vault":
    pts = []
    def rp(r, t, days, rule):
        return {"RecoveryPointArn": "arn:aws:rds:%s:%s:cluster-snapshot:awsbackup:job-%s-%d" % (r[3], acct, r[0], int(t.timestamp())),
                "BackupVaultName": opt("--backup-vault-name"), "ResourceArn": arn(r), "ResourceType": "DocumentDB" if r[1] == "docdb" else "Neptune",
                "CreationDate": iso(t), "Status": "COMPLETED", "BackupSizeInBytes": 10737418240,
                "CalculatedLifecycle": {"DeleteAt": iso(t + timedelta(days=days))}, "Lifecycle": {"DeleteAfterDays": days},
                "CreatedBy": {"BackupPlanId": "p1", "BackupPlanName": "docdb-plan", "BackupRuleId": "r-" + rule, "BackupRuleName": rule}}
    if opt("--backup-vault-name") == "prod vault":
        for r in rows:
            if r[6]:
                pts += [rp(r, t, 30, "weekly-sat") for t in saturdays(6) if t > created(r) and t + timedelta(days=30) > NOW]
            if r[7]:
                pts += [rp(r, t, 365, "monthly-first-sun") for t in first_sundays(13) if t > created(r) and t + timedelta(days=365) > NOW]
    elif rows:
        pts.append({"RecoveryPointArn": "arn:aws:ec2:%s::image/ami-0abc" % region, "ResourceArn": "arn:aws:ec2:%s:%s:instance/i-0abc" % (region, acct),
                    "ResourceType": "EC2", "CreationDate": iso(NOW), "Status": "COMPLETED"})
    print(json.dumps({"RecoveryPoints": pts})); sys.exit(0)
fail("InvalidAction", op, "mock: unsupported call %s %s" % (svc, op))
