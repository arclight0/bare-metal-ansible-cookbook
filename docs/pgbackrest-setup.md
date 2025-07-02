# pgBackRest Setup for PostgreSQL

This document describes the pgBackRest configuration for automated PostgreSQL backups with S3 storage.

## Overview

pgBackRest is configured to provide:
- **Continuous WAL archiving** - All transaction logs are automatically archived to S3
- **Weekly full backups** - Complete database backup every Sunday at 2:00 AM
- **Daily incremental backups** - Changed data backed up Monday-Saturday at 3:00 AM
- **Remote S3 storage** - All backups stored securely in Amazon S3 (or S3-compatible storage)
- **Automated verification** - Daily backup integrity checks at 4:30 AM

## Required Configuration

### S3 Credentials in Vault

Add the following variables to your `group_vars/all/vault.yml` file:

```yaml
# pgBackRest S3 Configuration
vault_pgbackrest_s3_bucket: "YOUR-BUCKET"
vault_pgbackrest_s3_region: "us-east-1"  # Optional, defaults to us-east-1
vault_pgbackrest_s3_endpoint: "s3.amazonaws.com"  # Optional, for S3-compatible storage
vault_pgbackrest_s3_key: "YOUR-AWS-ACCESS-KEY-ID"
vault_pgbackrest_s3_key_secret: "YOUR-AWS-SECRET-ACCESS-KEY"
```

If you don't have an existing S3 bucket, see the next section for how to create one with the correct permissions.

### S3 Bucket Setup

Create an S3 bucket for your PostgreSQL backups:

```bash
aws s3api create-bucket --bucket YOUR-BUCKET --region us-east-1
```

Create an IAM user:

```bash
aws iam create-user --user-name YOUR-USER
```

Create a policy, save as `s3-policy.json`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:PutObjectTagging",
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::YOUR-BUCKET/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::YOUR-BUCKET"
        }
    ]
}
```

Attach the policy to the user:

```bash
aws iam put-user-policy \
  --user-name YOUR-USER \
  --policy-name S3-Policy-YOUR-BUCKET \
  --policy-document file://s3-policy.json
```

Create access keys for the user:

```bash
aws iam create-access-key --user-name YOUR-USER
```

## Installation

1. Update your vault file with S3 credentials
2. Run the provision playbook (pgBackRest setup is included):
   ```bash
   ansible-playbook provision.yml
   ```

Or run just the pgBackRest setup:
```bash
ansible-playbook playbooks/provision/11_setup_pgbackrest.yml
```

## Usage

### Manual Operations

Use the utility playbook for manual operations:

```bash
# Check backup status and information
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=info

# Perform manual full backup
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=backup -e pgbackrest_backup_type=full

# Perform manual incremental backup
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=backup -e pgbackrest_backup_type=incr

# Check backup integrity
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=check

# Restore from latest backup
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=restore -e pgbackrest_restore_target=latest
```

### Scheduled Backups

Automated backups are configured via cron:
- **Full backup**: Every Sunday at 2:00 AM
- **Incremental backup**: Monday-Saturday at 3:00 AM
- **Verification**: Daily at 4:30 AM

### Monitoring

Check backup logs:
```bash
sudo tail -f /var/log/pgbackrest/backup.log
sudo tail -f /var/log/pgbackrest/check.log
```

View current backup status:
```bash
sudo -u postgres pgbackrest --stanza=main info
```

## Configuration Files

- **pgBackRest config**: `/etc/pgbackrest/pgbackrest.conf`
- **PostgreSQL config**: Modified in `/etc/postgresql/17/main/postgresql.conf`
- **Backup scripts**: `/usr/local/bin/pgbackrest-*-backup.sh`
- **Logs**: `/var/log/pgbackrest/`

## Backup Retention

- **Full backups**: 4 backups retained (approximately 1 month)
- **Incremental backups**: 4 backups retained per full backup
- **WAL archives**: Automatically cleaned up when no longer needed

## Recovery Scenarios

### Point-in-Time Recovery

To restore to a specific point in time:

```bash
# Stop PostgreSQL
sudo systemctl stop postgresql

# Restore to specific timestamp
sudo -u postgres pgbackrest --stanza=main restore --type=time --target="2024-01-15 14:30:00"

# Start PostgreSQL
sudo systemctl start postgresql
```

### Full Recovery from Latest Backup

```bash
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=restore
```

## Troubleshooting

### Common Issues

1. **S3 Connection Issues**: Verify credentials and bucket permissions
2. **WAL Archive Failures**: Check PostgreSQL logs and pgBackRest configuration
3. **Backup Failures**: Check `/var/log/pgbackrest/backup.log` for details

### Verification Commands

```bash
# Test S3 connectivity
sudo -u postgres pgbackrest --stanza=main check

# Verify PostgreSQL archiving
sudo -u postgres psql -c "SELECT pg_switch_wal();"
sudo -u postgres pgbackrest --stanza=main info

# Check PostgreSQL WAL archiving status
sudo -u postgres psql -c "SELECT name, setting FROM pg_settings WHERE name LIKE 'archive%';"
```

## Security Considerations

1. **Encryption**: All backups are compressed with LZ4 for performance
2. **Access Control**: S3 bucket should have restricted IAM policies
3. **Network**: Consider VPC endpoints for S3 traffic
4. **Monitoring**: Set up CloudWatch alarms for backup failures

## Performance Tuning

Current settings optimize for:
- **Compression**: LZ4 (fast compression/decompression)
- **Parallelism**: 4 processes for backup operations
- **Network**: Optimized for typical cloud environments

Adjust these in `group_vars/postgres.yml` if needed:
```yaml
pgbackrest_process_max: 4
pgbackrest_compress_type: lz4
pgbackrest_compress_level: 1
```
