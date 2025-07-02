# Cloudflare Tunnels Setup Guide

This guide explains how to set up Cloudflare Tunnels for your demo app K3s cluster, enabling secure access to your applications from the internet.

## Overview

Cloudflare Tunnels provide a secure way to expose your internal applications to the internet without opening ports on your firewall. The setup supports multiple applications and can be easily extended for future use.

## Prerequisites

Before starting, ensure you have:

1. **Cloudflare Account**: A Cloudflare account with a domain configured
2. **Domain Management**: Your domain's nameservers pointing to Cloudflare
3. **K3s Cluster**: A running K3s cluster with kubectl access
4. **Internet Access**: Ability to download and install `cloudflared`

## Quick Setup (Automated)

### Step 1: Make the Setup Script Executable

```bash
chmod +x scripts/setup-cloudflare-tunnel.sh
```

### Step 2: Run the Setup Script

```bash
./scripts/setup-cloudflare-tunnel.sh YOUR_TUNNEL_NAME
```

The script will:
1. Install `cloudflared` if not present
2. Authenticate with Cloudflare (if not already auth'd)
3. Create a tunnel named `YOUR_TUNNEL_NAME`
4. Configure DNS records
5. Deploy the tunnel controller to your K3s cluster

### Step 3: Deploy Your Application

Ensure your `db-test-app` is running:

```bash
kubectl apply -f examples/db-test-app.yaml
```

### Step 4: Access Your Application

After setup, your application will be available at:
- `https://<yourdomain>`

## Manual Setup (Advanced)

If you prefer manual setup or need to customize the configuration:

### 1. Install cloudflared

#### Linux
```bash
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared-linux-amd64
sudo mv cloudflared-linux-amd64 /usr/local/bin/cloudflared
```

#### macOS
```bash
brew install cloudflared
```

### 2. Authenticate with Cloudflare

```bash
cloudflared tunnel login
```

This opens a browser for authentication.

### 3. Create a Tunnel

```bash
cloudflared tunnel create YOUR_TUNNEL_NAME
```

Note the tunnel ID returned by this command.

### 4. Configure DNS

Replace `YOUR_TUNNEL_ID` and `db-test.yourdomain.com` with your actual values:

```bash
cloudflared tunnel route dns YOUR_TUNNEL_ID db-test.yourdomain.com
```

### 5. Create Kubernetes Secret

```bash
# Create namespace
kubectl create namespace cloudflare-tunnels

# Create secret with credentials
kubectl create secret generic tunnel-credentials \
    --namespace=cloudflare-tunnels \
    --from-file=credentials.json=$HOME/.cloudflared/YOUR_TUNNEL_ID.json
```

### 6. Deploy Tunnel Controller

Edit `examples/cloudflare-tunnel-controller.yaml` to replace:
- `TUNNEL_ID_PLACEHOLDER` with your actual tunnel ID
- `db-test.yourdomain.com` with your actual domain

Then deploy:

```bash
kubectl apply -f examples/cloudflare-tunnel-controller.yaml
```

## Adding Additional Applications

To add more applications to your tunnel:

### 1. Create DNS Record

```bash
cloudflared tunnel route dns YOUR_TUNNEL_ID app2.yourdomain.com
```

### 2. Update Tunnel Configuration

Edit the tunnel configuration:

```bash
kubectl edit configmap tunnel-configs -n cloudflare-tunnels
```

Add a new ingress rule in the `tunnel-config.yaml` section:

```yaml
ingress:
  # Existing db-test-app route
  - hostname: db-test.yourdomain.com
    service: http://db-test-service.default.svc.cluster.local:80

  # New application route
  - hostname: app2.yourdomain.com
    service: http://app2-service.default.svc.cluster.local:80

  # Catch-all rule (must be last)
  - service: http_status:404
```

### 3. Restart Tunnel Pods

```bash
kubectl rollout restart deployment/cloudflared -n cloudflare-tunnels
```

## Monitoring and Troubleshooting

### Check Tunnel Status

```bash
# Check pod status
kubectl get pods -n cloudflare-tunnels

# Check logs
kubectl logs -n cloudflare-tunnels -l app=cloudflared

# Check tunnel configuration
kubectl describe configmap tunnel-configs -n cloudflare-tunnels
```

### Verify Tunnel Connection

```bash
# From your local machine
cloudflared tunnel list

# Check specific tunnel
cloudflared tunnel info YOUR_TUNNEL_ID
```

### Common Issues

#### 1. Pod CrashLoopBackOff

Check if credentials are properly mounted:

```bash
kubectl describe pod -n cloudflare-tunnels -l app=cloudflared
```

#### 2. 404 Errors

Verify the service name and namespace in your tunnel configuration:

```bash
kubectl get services -A | grep db-test
```

#### 3. DNS Not Resolving

Check if DNS record was created:

```bash
nslookup db-test.yourdomain.com
```

## Configuration Reference

### Tunnel Configuration Structure

```yaml
tunnel: YOUR_TUNNEL_ID
credentials-file: /etc/cloudflared/credentials.json

ingress:
  # Application routes
  - hostname: app.yourdomain.com
    service: http://app-service.namespace.svc.cluster.local:PORT

  # Path-based routing (optional)
  - hostname: api.yourdomain.com
    path: /v1/*
    service: http://api-service.default.svc.cluster.local:3000

  # WebSocket support (optional)
  - hostname: ws.yourdomain.com
    service: http://websocket-service.default.svc.cluster.local:8080
    originRequest:
      noTLSVerify: true

  # Catch-all rule (required)
  - service: http_status:404
```

### Advanced Features

#### Load Balancing

Configure multiple replicas for high availability:

```yaml
spec:
  replicas: 3  # Scale based on your needs
```

#### Custom Origin Certificates

For internal HTTPS services:

```yaml
- hostname: secure-app.yourdomain.com
  service: https://secure-service.default.svc.cluster.local:443
  originRequest:
    noTLSVerify: true  # For self-signed certificates
```

#### Access Control

Use Cloudflare Access for authentication:

```yaml
- hostname: protected.yourdomain.com
  service: http://protected-service.default.svc.cluster.local:80
  originRequest:
    access:
      required: true
      teamName: your-team
```

## Security Considerations

1. **Credentials Management**: Store tunnel credentials securely in Kubernetes secrets
2. **Network Policies**: Implement Kubernetes network policies to restrict traffic
3. **Access Control**: Use Cloudflare Access for sensitive applications
4. **Monitoring**: Monitor tunnel logs for unusual activity
5. **Regular Updates**: Keep `cloudflared` image updated

## Cleanup

To remove the tunnel setup:

```bash
# Delete Kubernetes resources
kubectl delete namespace cloudflare-tunnels

# Delete tunnel (from local machine)
cloudflared tunnel delete YOUR_TUNNEL_NAME

# Remove DNS records from Cloudflare dashboard
```

## Support

For issues and questions:

1. Check the [Cloudflare Tunnel documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
2. Review Kubernetes logs: `kubectl logs -n cloudflare-tunnels -l app=cloudflared`
3. Verify network connectivity between pods and services
