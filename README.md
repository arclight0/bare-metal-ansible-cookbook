# Bare Metal Ansible cookbook

This project uses Ansible to automate the deployment of:
- Ubuntu Cloud-Init VMs on Proxmox
- K3s Kubernetes cluster
- PostgreSQL database with pgBackRest backup solution
- Redis key-value store

Additional scripts automate the deployment of:
- Demo web application running on Kubernetes
- Cloudflare tunnel to expose our demo app to the internet

## Prerequisites

- Proxmox server access via Web and SSH
- `uv` for Python dependency management (installed by `initialize.sh`)
- AWS S3 bucket for PostgreSQL backups (see `docs/pgbackrest-setup.md` for S3 setup instructions)
- Cloud-Init image downloaded to Proxmox storage (default: `/var/lib/vz/images/noble-server-cloudimg-amd64.img`)

## Setup

1. Run the initialization script:
   ```
   ./initialize.sh
   ```

2. Activate the Python virtual environment:
   ```
   source .venv/bin/activate
   ```

3. Encrypt the vault file using a generated password:
   ```
   openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c32 > ~/.ansible_vault_pass
   chmod 600 ~/.ansible_vault_pass
   ansible-vault encrypt group_vars/all/vault.yml --vault-password-file ~/.ansible_vault_pass
   ```

4. After encrypting, secrets can be edited with this command:
   ```
   ansible-vault edit group_vars/all/vault.yml
   ```
   Proceed with updating placeholder config values

## Configuration

### Basic Configuration
- Modify the VM specifications in `group_vars/all/vms.yml`
- Configure PostgreSQL settings in `group_vars/postgres.yml` (see [PGTune] for hardware-specific recommendations)
- Configure Redis settings in `group_vars/redis.yml`
- Configure K3s settings in `playbooks/provision/30_setup_k3s.yml`

[PGTune]: https://pgtune.leopard.in.ua/

### pgBackRest Backup Configuration
For PostgreSQL backups with S3 storage, add these variables to `group_vars/all/vault.yml`:

```yaml
# pgBackRest S3 Configuration
vault_pgbackrest_s3_bucket: "your-postgres-backups-bucket"
vault_pgbackrest_s3_region: "us-east-1"
vault_pgbackrest_s3_key: "your-aws-access-key-id"
vault_pgbackrest_s3_key_secret: "your-aws-secret-access-key"
```

See `docs/pgbackrest-setup.md` for detailed configuration instructions.

## Usage

To provision everything:

```bash
ansible-playbook provision.yml
```

When that's complete, initialize application databases with:

```bash
ansible-playbook application.yml
```

Note: if you don't want to run the entire provisioning playbook for everything at once, or if you run into problems with a particular playbook, you can run and re-run individual provisioning playbooks on their own (provisioning playbooks are idempotent so re-running is safe):

```bash
# Create VMs only
ansible-playbook playbooks/provision/01_create_vms.yml

# Set up PostgreSQL
ansible-playbook playbooks/provision/10_setup_postgres.yml

# Set up pgBackRest (requires S3 configuration)
ansible-playbook playbooks/provision/11_setup_pgbackrest.yml

# Set up K3s cluster
ansible-playbook playbooks/provision/20_setup_k3s.yml
```

## Accessing the K3s Cluster

After provisioning is complete, the K3s kubeconfig file will be saved to `files/k3s.yaml`.

To use this config file:

```bash
export KUBECONFIG=$(pwd)/files/k3s.yaml
kubectl cluster-info
```

And you should see the running Kubernetes (K8s) cluster info.

## Deploy demo application

With Kubernetes running, the demo application can be deployed with (note: this YAML is a template filled in when running the `application.yml` Ansible playbook):

```
kubectl apply -f examples/db-test-app.yaml
```

Once the service comes up, you should be able to test it:

```
$ kubectl get svc
NAME                  TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
db-test-service       NodePort    10.43.218.38   <none>        80:32221/TCP   21h
kubernetes            ClusterIP   10.43.0.1      <none>        443/TCP        16d

$ curl http://k3s-master-01.YOUR-TAILNET.ts.net:32221/json

{"postgres":{"current_database":"myproject_db","current_user":"appuser","database_size":"15 MB","postgis_available":true,"status":"success","time":"2025-06-18T17:17:04.483073+00:00","version":"PostgreSQL 17.5 (Ubuntu 17.5-1.pgdg24.04+1) on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0, 64-bit"},"redis":{"connected_clients":1,"current_user":"appuser","memory_used":"1.20M","status":"success","test_key":"db_test:20250618_171704","test_value":"2025-06-18T17:17:04.488058","version":"7.2.9"},"timestamp":"2025-06-18T17:17:04.488795"}
```

## Cloudflare tunnel

With the service running, you can now expose it to the public internet using a custom domain name by using Cloudflare tunnels:

```
$ chmod u+x scripts/setup-cloudflare-tunnel.sh
$ scripts/setup-cloudflare-tunnel.sh arclight-k3s-tunnel
```

The script will guide you through setting up `cloudflared` if you don't have it installed, authenticating with Cloudflare, and creating a Cloudflare domain to route traffic through to your tunnel.

When finished, you should be able to visit your domain name in a web browser and see the demo app running there.

## Accessing PostgreSQL

PostgreSQL gets installed on the `postgres-01` VM and configured to allow connections from the K3s cluster nodes over the shared network bridge. The cluster nodes will connect directly over the local 10.0.0.x network (not Tailscale).

To connect from your development machine, however, you can use your Tailscale network:

```bash
psql -h postgres-01.YOUR-TAILNET.ts.net -U appuser -d myproject_db
```

## PostgreSQL Backup and Recovery

PostgreSQL is configured with pgBackRest for enterprise-grade backup and recovery:

- **Continuous WAL archiving** to S3
- **Weekly full backups** (Sunday 2:00 AM)
- **Daily incremental backups** (Monday-Saturday 3:00 AM)
- **Point-in-time recovery** capability
- **Automated backup verification** (daily 4:30 AM)

For detailed backup and recovery procedures, see `docs/pgbackrest-setup.md`.

### Backup Operations

Manage PostgreSQL backups using the utility playbook:

```bash
# Check backup status
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=info

# Perform manual backup
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=backup -e pgbackrest_backup_type=full

# Restore from backup
ansible-playbook playbooks/pgbackrest_operations.yml -e pgbackrest_operation=restore
```
