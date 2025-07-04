#!/bin/bash

# Cloudflare Tunnel Setup Script
# This script helps you create and configure Cloudflare tunnels for your applications

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if tunnel name is provided as first argument
if [[ -z "$1" ]]; then
    echo -e "${RED}❌ Usage: $0 <tunnel-name>${NC}"
    echo -e "${YELLOW}Example: $0 arclight-k3s-tunnel${NC}"
    exit 1
fi

# Configuration
TUNNEL_NAME="$1"
DOMAIN="" # Will be set by user input
NAMESPACE="cloudflare-tunnels"

echo -e "${BLUE}🌐 Cloudflare Tunnel Setup for K3s Cluster${NC}"
echo "=================================================="
echo -e "${BLUE}Tunnel Name: ${TUNNEL_NAME}${NC}"

# Check if cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo -e "${RED}❌ cloudflared is not installed. Installing...${NC}"

    # Detect OS and install cloudflared
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x cloudflared-linux-amd64
        sudo mv cloudflared-linux-amd64 /usr/local/bin/cloudflared
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install cloudflared
        else
            echo -e "${RED}❌ Please install Homebrew first or manually install cloudflared${NC}"
            exit 1
        fi
    else
        echo -e "${RED}❌ Unsupported OS. Please install cloudflared manually${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ cloudflared installed successfully${NC}"
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}❌ Cannot connect to Kubernetes cluster. Please check your kubeconfig${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"

# Get domain from user
echo ""
echo -e "${YELLOW}📝 Configuration${NC}"
read -p "Enter your full domain (e.g., db-test.example.com): " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}❌ Domain is required${NC}"
    exit 1
fi

# Check if already authenticated
echo ""
echo -e "${YELLOW}🔐 Cloudflare Authentication${NC}"
if cloudflared tunnel list &> /dev/null; then
    echo -e "${GREEN}✅ Already authenticated with Cloudflare${NC}"
else
    echo "Please log in to Cloudflare (this will open a browser)..."
    cloudflared tunnel login

    # Verify authentication worked
    if ! cloudflared tunnel list &> /dev/null; then
        echo -e "${RED}❌ Authentication failed. Please try again${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Successfully authenticated with Cloudflare${NC}"
fi

# Create tunnel
echo ""
echo -e "${YELLOW}🚇 Creating Cloudflare Tunnel${NC}"

# First check if tunnel already exists
EXISTING_TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}' || echo "")

if [[ -n "$EXISTING_TUNNEL_ID" ]]; then
    TUNNEL_ID="$EXISTING_TUNNEL_ID"
    echo -e "${YELLOW}⚠️  Tunnel $TUNNEL_NAME already exists with ID: $TUNNEL_ID${NC}"
else
    # Create new tunnel and capture output
    CREATE_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    echo "$CREATE_OUTPUT"

    # Extract tunnel ID using multiple methods for reliability
    TUNNEL_ID=$(echo "$CREATE_OUTPUT" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)

    if [[ -z "$TUNNEL_ID" ]]; then
        # Fallback: try to find it in the tunnel list
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}' || echo "")
    fi

    if [[ -z "$TUNNEL_ID" ]]; then
        echo -e "${RED}❌ Failed to create tunnel or extract tunnel ID${NC}"
        echo -e "${RED}Create output: $CREATE_OUTPUT${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ Tunnel created with ID: $TUNNEL_ID${NC}"
    fi
fi

# Create DNS record for the specified domain
echo ""
echo -e "${YELLOW}🌐 Creating DNS Records${NC}"
cloudflared tunnel route dns $TUNNEL_ID $DOMAIN

echo -e "${GREEN}✅ DNS record created: $DOMAIN${NC}"

# Get credentials file location
CREDENTIALS_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo -e "${RED}❌ Credentials file not found at $CREDENTIALS_FILE${NC}"
    exit 1
fi

# Create namespace
echo ""
echo -e "${YELLOW}☸️  Setting up Kubernetes resources${NC}"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create secret with credentials
kubectl create secret generic tunnel-credentials \
    --namespace=$NAMESPACE \
    --from-file=credentials.json=$CREDENTIALS_FILE

# Update the tunnel configuration
echo ""
echo -e "${YELLOW}📝 Updating tunnel configuration${NC}"

# Create temporary config file with the correct tunnel ID and domain
cat > /tmp/tunnel-config.yaml << EOF
# Cloudflare Tunnel Controller for Multiple Applications
# This setup allows you to manage multiple Cloudflare tunnels from a single deployment

# Namespace for all tunnel-related resources
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflare-tunnels
---
# ConfigMap for tunnel configurations
apiVersion: v1
kind: ConfigMap
metadata:
  name: tunnel-configs
  namespace: cloudflare-tunnels
data:
  # Main tunnel configuration - supports multiple ingress rules
  tunnel-config.yaml: |
    tunnel: $TUNNEL_ID
    credentials-file: /etc/cloudflared/credentials.json

    ingress:
      # Route for the specified domain
      - hostname: $DOMAIN
        service: http://db-test-service.default.svc.cluster.local:80

      # Route for future apps - add more as needed
      # - hostname: hello-world-app.$DOMAIN
      #   service: http://hello-world-service.default.svc.cluster.local:80

      # Catch-all rule (required)
      - service: http_status:404
---
# Secret to store tunnel credentials (managed by script)
apiVersion: v1
kind: Secret
metadata:
  name: tunnel-credentials
  namespace: cloudflare-tunnels
type: Opaque
# Data will be populated by the setup script
---
# Deployment for cloudflared
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare-tunnels
  labels:
    app: cloudflared
spec:
  replicas: 2  # For high availability
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args:
        - tunnel
        - --config
        - /etc/cloudflared/config/tunnel-config.yaml
        - run
        volumeMounts:
        - name: config
          mountPath: /etc/cloudflared/config
          readOnly: true
        - name: credentials
          mountPath: /etc/cloudflared
          readOnly: true
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
      volumes:
      - name: config
        configMap:
          name: tunnel-configs
      - name: credentials
        secret:
          secretName: tunnel-credentials
---
# Service for cloudflared (for monitoring)
apiVersion: v1
kind: Service
metadata:
  name: cloudflared-service
  namespace: cloudflare-tunnels
spec:
  selector:
    app: cloudflared
  ports:
  - name: metrics
    port: 2000
    targetPort: 2000
EOF

# Apply the configuration
kubectl apply -f /tmp/tunnel-config.yaml

# Clean up temporary file
rm /tmp/tunnel-config.yaml

# Optionally create ServiceMonitor if Prometheus Operator is available
echo ""
echo -e "${YELLOW}📊 Setting up monitoring (optional)${NC}"
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    echo "Creating ServiceMonitor for Prometheus..."
    cat > /tmp/servicemonitor.yaml << EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cloudflared-metrics
  namespace: cloudflare-tunnels
spec:
  selector:
    matchLabels:
      app: cloudflared
  endpoints:
  - port: metrics
    path: /metrics
EOF
    kubectl apply -f /tmp/servicemonitor.yaml
    rm /tmp/servicemonitor.yaml
    echo -e "${GREEN}✅ ServiceMonitor created for Prometheus monitoring${NC}"
else
    echo -e "${YELLOW}⚠️  Prometheus Operator not found, skipping ServiceMonitor creation${NC}"
    echo -e "${YELLOW}    (This is optional - tunnel will work without it)${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Setup Complete!${NC}"
echo ""
echo -e "${BLUE}📋 Summary:${NC}"
echo "  Tunnel Name: $TUNNEL_NAME"
echo "  Tunnel ID: $TUNNEL_ID"
echo "  Domain: $DOMAIN"
echo ""
echo -e "${BLUE}🔗 Access your application:${NC}"
echo "  https://$DOMAIN"
echo ""
echo -e "${BLUE}📊 Monitor tunnel status:${NC}"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl logs -n $NAMESPACE -l app=cloudflared"
echo ""
echo -e "${YELLOW}💡 To add more applications:${NC}"
echo "  1. Create DNS records: cloudflared tunnel route dns $TUNNEL_ID <subdomain>.$DOMAIN"
echo "  2. Update the ConfigMap: kubectl edit configmap tunnel-configs -n $NAMESPACE"
echo "  3. Add new ingress rules to the tunnel-config.yaml section"
echo ""
echo -e "${GREEN}✅ Your db-test-app is now accessible via Cloudflare Tunnel!${NC}"
