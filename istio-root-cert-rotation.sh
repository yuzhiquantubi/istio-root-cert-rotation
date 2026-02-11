#!/bin/bash

#############################################################################
# Istio Root Certificate Rotation Script
#
# This script handles rotation from Istio's default self-signed CA to a
# custom CA certificate, following the four-phase approach for zero-downtime.
#
# Based on:
# - https://docs.tetrate.io/istio-subscription/howto/root-cert-rotation
# - https://github.com/zirain/istio-root-cert-rotation
#
# Prerequisites:
# - kubectl configured with cluster access
# - istioctl installed
# - step CLI installed (brew install step)
# - openssl installed
#############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
WORK_DIR="${WORK_DIR:-./cert-rotation-workspace}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
TEST_NAMESPACE="${TEST_NAMESPACE:-cert-rotation-test}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"  # 10 years for root CA
INTERMEDIATE_VALIDITY_DAYS="${INTERMEDIATE_VALIDITY_DAYS:-365}"  # 1 year for intermediate

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()

    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi

    if ! command -v istioctl &> /dev/null; then
        missing_tools+=("istioctl")
    fi

    if ! command -v step &> /dev/null; then
        missing_tools+=("step (install with: brew install step)")
    fi

    if ! command -v openssl &> /dev/null; then
        missing_tools+=("openssl")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    log_success "All prerequisites met"
}

# Check Istio configuration for multi-root support
check_istio_config() {
    log_info "Checking Istio configuration for multi-root support..."

    # Check ISTIO_MULTIROOT_MESH
    local multiroot=$(kubectl get deploy istiod -n "$ISTIO_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | grep -o '"ISTIO_MULTIROOT_MESH"' || true)

    if [ -z "$multiroot" ]; then
        log_warning "ISTIO_MULTIROOT_MESH is not enabled on istiod"
        log_warning "You need to update your Istio installation with:"
        echo ""
        echo "  values:"
        echo "    pilot:"
        echo "      env:"
        echo "        ISTIO_MULTIROOT_MESH: \"true\""
        echo ""
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "ISTIO_MULTIROOT_MESH is enabled"
    fi

    # Check PROXY_CONFIG_XDS_AGENT
    local xds_agent=$(kubectl get cm istio -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.mesh}' 2>/dev/null | grep "PROXY_CONFIG_XDS_AGENT" || true)

    if [ -z "$xds_agent" ]; then
        log_warning "PROXY_CONFIG_XDS_AGENT may not be enabled in mesh config"
        log_warning "You need to update your Istio installation with:"
        echo ""
        echo "  meshConfig:"
        echo "    defaultConfig:"
        echo "      proxyMetadata:"
        echo "        PROXY_CONFIG_XDS_AGENT: \"true\""
        echo ""
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "PROXY_CONFIG_XDS_AGENT is enabled"
    fi
}

# Extract current self-signed root certificate from Istio
extract_current_root_cert() {
    log_info "Extracting current Istio self-signed root certificate..."

    mkdir -p "$WORK_DIR/rootA"

    # Check if using self-signed CA (istio-ca-secret) or plugged-in CA (cacerts)
    if kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" &> /dev/null; then
        log_info "Found self-signed CA secret (istio-ca-secret)"

        # Extract root certificate from istio-ca-secret
        kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > "$WORK_DIR/rootA/root-cert.pem"
        kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > "$WORK_DIR/rootA/ca-cert.pem"
        kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.ca-key\.pem}' | base64 -d > "$WORK_DIR/rootA/ca-key.pem"

        # For self-signed CA, cert-chain is the same as ca-cert
        cp "$WORK_DIR/rootA/ca-cert.pem" "$WORK_DIR/rootA/cert-chain.pem"

    elif kubectl get secret cacerts -n "$ISTIO_NAMESPACE" &> /dev/null; then
        log_info "Found plugged-in CA secret (cacerts)"

        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.root-cert\.pem}' | base64 -d > "$WORK_DIR/rootA/root-cert.pem"
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > "$WORK_DIR/rootA/ca-cert.pem"
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.ca-key\.pem}' | base64 -d > "$WORK_DIR/rootA/ca-key.pem"
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath='{.data.cert-chain\.pem}' | base64 -d > "$WORK_DIR/rootA/cert-chain.pem"
    else
        log_error "No CA secret found in $ISTIO_NAMESPACE namespace"
        log_error "Expected either 'istio-ca-secret' (self-signed) or 'cacerts' (plugged-in)"
        exit 1
    fi

    log_success "Extracted current root certificate to $WORK_DIR/rootA/"

    # Display certificate info
    log_info "Current root certificate info:"
    step certificate inspect "$WORK_DIR/rootA/root-cert.pem" --short
}

# Generate new root certificate and intermediate CA
generate_new_certificates() {
    log_info "Generating new root certificate (Root B)..."

    mkdir -p "$WORK_DIR/rootB/intermediateB"

    # Generate new root CA
    openssl genrsa -out "$WORK_DIR/rootB/root-key.pem" 4096

    openssl req -new -x509 -days "$CERT_VALIDITY_DAYS" \
        -key "$WORK_DIR/rootB/root-key.pem" \
        -out "$WORK_DIR/rootB/root-cert.pem" \
        -subj "/O=Istio/CN=Root CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    log_success "Generated new root CA"

    # Generate intermediate CA
    log_info "Generating intermediate CA for Root B..."

    openssl genrsa -out "$WORK_DIR/rootB/intermediateB/ca-key.pem" 4096

    openssl req -new \
        -key "$WORK_DIR/rootB/intermediateB/ca-key.pem" \
        -out "$WORK_DIR/rootB/intermediateB/ca-csr.pem" \
        -subj "/O=Istio/CN=Intermediate CA"

    # Create extension file for intermediate CA
    cat > "$WORK_DIR/rootB/intermediateB/intermediate-ext.cnf" << EOF
[v3_intermediate_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

    openssl x509 -req -days "$INTERMEDIATE_VALIDITY_DAYS" \
        -in "$WORK_DIR/rootB/intermediateB/ca-csr.pem" \
        -CA "$WORK_DIR/rootB/root-cert.pem" \
        -CAkey "$WORK_DIR/rootB/root-key.pem" \
        -CAcreateserial \
        -out "$WORK_DIR/rootB/intermediateB/ca-cert.pem" \
        -extfile "$WORK_DIR/rootB/intermediateB/intermediate-ext.cnf" \
        -extensions v3_intermediate_ca

    # Copy root cert
    cp "$WORK_DIR/rootB/root-cert.pem" "$WORK_DIR/rootB/intermediateB/root-cert.pem"

    # Create cert chain (intermediate + root)
    cat "$WORK_DIR/rootB/intermediateB/ca-cert.pem" "$WORK_DIR/rootB/root-cert.pem" > "$WORK_DIR/rootB/intermediateB/cert-chain.pem"

    log_success "Generated intermediate CA"

    # Display new certificate info
    log_info "New root certificate info:"
    step certificate inspect "$WORK_DIR/rootB/root-cert.pem" --short

    log_info "New intermediate certificate info:"
    step certificate inspect "$WORK_DIR/rootB/intermediateB/ca-cert.pem" --short
}

# Create combined root certificate files
create_combined_roots() {
    log_info "Creating combined root certificate files..."

    # combined-root.pem = Root A + Root B
    cat "$WORK_DIR/rootA/root-cert.pem" "$WORK_DIR/rootB/root-cert.pem" > "$WORK_DIR/combined-root.pem"

    # combined-root2.pem = Root A + Root B + Root B (for transition phase)
    cat "$WORK_DIR/rootA/root-cert.pem" "$WORK_DIR/rootB/root-cert.pem" "$WORK_DIR/rootB/root-cert.pem" > "$WORK_DIR/combined-root2.pem"

    log_success "Created combined root certificate files"

    # Verify combined certificates
    log_info "Combined root (A+B) contains:"
    step certificate inspect "$WORK_DIR/combined-root.pem" --short
}

# Backup current state
backup_current_state() {
    log_info "Backing up current CA secrets..."

    mkdir -p "$WORK_DIR/backup"

    if kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" &> /dev/null; then
        kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" -o yaml > "$WORK_DIR/backup/istio-ca-secret.yaml"
        log_success "Backed up istio-ca-secret"
    fi

    if kubectl get secret cacerts -n "$ISTIO_NAMESPACE" &> /dev/null; then
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o yaml > "$WORK_DIR/backup/cacerts.yaml"
        log_success "Backed up cacerts"
    fi

    log_success "Backup completed to $WORK_DIR/backup/"
}

# Verify workload certificates
verify_workload_certs() {
    local namespace="${1:-default}"
    local app_label="${2:-}"

    log_info "Verifying workload certificates..."

    local pods
    if [ -n "$app_label" ]; then
        pods=$(kubectl get pod -n "$namespace" -l "$app_label" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    else
        pods=$(kubectl get pod -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | head -1 || true)
    fi

    if [ -z "$pods" ]; then
        log_warning "No pods found in namespace $namespace"
        return
    fi

    for pod in $pods; do
        log_info "Checking certificate for pod: $pod"
        istioctl pc secret "$pod.$namespace" -ojson 2>/dev/null | \
            jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes // empty' | \
            base64 -d 2>/dev/null | \
            step certificate inspect --short - 2>/dev/null || log_warning "Could not inspect certificate for $pod"
        break  # Only check first pod
    done
}

# Check traffic health
check_traffic_health() {
    local namespace="${1:-default}"
    local pod="${2:-}"

    if [ -z "$pod" ]; then
        pod=$(kubectl get pod -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi

    if [ -z "$pod" ]; then
        log_warning "No pods found to check traffic health"
        return
    fi

    log_info "Checking traffic health metrics for $pod..."
    istioctl x es "$pod.$namespace" -oprom 2>/dev/null | grep "istio_requests_total" | head -5 || log_warning "No metrics available"
}

# Deploy test workloads for certificate rotation testing
deploy_test_workloads() {
    log_info "Deploying test workloads for certificate rotation testing..."

    # Create test namespace with Istio injection enabled
    kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$TEST_NAMESPACE" istio-injection=enabled --overwrite

    # Deploy server workload
    log_info "Deploying test server..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-server
  namespace: $TEST_NAMESPACE
  labels:
    app: test-server
spec:
  ports:
  - port: 8080
    name: http
  selector:
    app: test-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-server
  namespace: $TEST_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-server
  template:
    metadata:
      labels:
        app: test-server
    spec:
      containers:
      - name: server
        image: python:3.12-alpine
        command: ["python", "-c"]
        args:
        - |
          from http.server import HTTPServer, BaseHTTPRequestHandler
          import socket
          import datetime
          import os

          LOG_FILE = '/shared/server.log'
          REQUEST_COUNT = [0]  # Use list for mutable counter

          def write_log(msg):
              with open(LOG_FILE, 'a') as f:
                  f.write(msg + '\n')
              print(msg, flush=True)
              # Keep only last 1000 lines
              if REQUEST_COUNT[0] % 100 == 0:
                  try:
                      with open(LOG_FILE, 'r') as f:
                          lines = f.readlines()[-1000:]
                      with open(LOG_FILE, 'w') as f:
                          f.writelines(lines)
                  except:
                      pass

          class Handler(BaseHTTPRequestHandler):
              def do_GET(self):
                  REQUEST_COUNT[0] += 1
                  ts = datetime.datetime.now().isoformat()
                  client_ip = self.client_address[0]
                  self.send_response(200)
                  self.send_header('Content-Type', 'text/plain')
                  self.end_headers()
                  response = f"Server: {socket.gethostname()}\nTime: {ts}\nStatus: OK\n"
                  self.wfile.write(response.encode())
                  write_log(f"[{ts}] REQUEST #{REQUEST_COUNT[0]} from {client_ip} - {self.requestline} - 200 OK")

              def log_message(self, format, *args):
                  pass  # Use custom logging instead

          # Initialize log file
          with open(LOG_FILE, 'w') as f:
              f.write(f"Server started at {datetime.datetime.now().isoformat()}\n")

          server = HTTPServer(('0.0.0.0', 8080), Handler)
          print(f'Server running on port 8080, logging to {LOG_FILE}')
          server.serve_forever()
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: share
          mountPath: /shared
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
      volumes:
      - name: share
        emptyDir: {}
EOF

    # Deploy client workload that continuously tests connectivity
    log_info "Deploying test client..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-client
  namespace: $TEST_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-client
  template:
    metadata:
      labels:
        app: test-client
    spec:
      containers:
      - name: client
        image: curlimages/curl:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          # Continuous connectivity test with detailed error logging
          LOG_FILE=/shared/connectivity.log
          RESP_FILE=/tmp/response.txt
          SUCCESS_COUNT=0
          FAIL_COUNT=0

          # Log to both file and stdout
          log_msg() {
            echo "\$1" | tee -a \$LOG_FILE
          }

          log_msg "Starting connectivity test at \$(date -Iseconds)"
          while true; do
            TIMESTAMP=\$(date -Iseconds)
            # Capture response body, HTTP code, and timing info
            HTTP_CODE=\$(curl -s -o \$RESP_FILE -w "%{http_code}" --connect-timeout 5 --max-time 10 http://test-server:8080 2>/tmp/curl_error.txt)
            CURL_EXIT=\$?

            if [ "\$HTTP_CODE" = "200" ] && [ "\$CURL_EXIT" -eq 0 ]; then
              SUCCESS_COUNT=\$((SUCCESS_COUNT + 1))
              log_msg "[\$TIMESTAMP] SUCCESS (total: \$SUCCESS_COUNT, failed: \$FAIL_COUNT)"
            else
              FAIL_COUNT=\$((FAIL_COUNT + 1))
              # Collect detailed error info
              CURL_ERROR=""
              RESP_BODY=""
              if [ -s /tmp/curl_error.txt ]; then
                CURL_ERROR=\$(cat /tmp/curl_error.txt | tr '\n' ' ')
              fi
              if [ -s \$RESP_FILE ]; then
                RESP_BODY=\$(head -c 500 \$RESP_FILE | tr '\n' ' ')
              fi
              # Log detailed failure info to both file and stdout
              log_msg "[\$TIMESTAMP] FAILED - HTTP:\$HTTP_CODE curl_exit:\$CURL_EXIT (total: \$SUCCESS_COUNT, failed: \$FAIL_COUNT)"
              if [ -n "\$CURL_ERROR" ]; then
                log_msg "  curl_error: \$CURL_ERROR"
              fi
              if [ -n "\$RESP_BODY" ]; then
                log_msg "  response: \$RESP_BODY"
              fi
            fi
            # Keep only last 1000 lines
            tail -1000 \$LOG_FILE > \$LOG_FILE.tmp && mv \$LOG_FILE.tmp \$LOG_FILE 2>/dev/null || true
            sleep 1
          done
        volumeMounts:
        - name: share
          mountPath: /shared
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
      volumes:
      - name: share
        emptyDir: {}
EOF

    log_info "Waiting for test workloads to be ready..."
    kubectl rollout status deployment/test-server -n "$TEST_NAMESPACE" --timeout=120s
    kubectl rollout status deployment/test-client -n "$TEST_NAMESPACE" --timeout=120s

    log_success "Test workloads deployed successfully"
    log_info "Client is continuously testing connectivity to server"
    log_info "Use '$0 test-status' to check connectivity status"
}

# Check test workload connectivity status
check_test_status() {
    log_info "=========================================="
    log_info "Test Workload Connectivity Status"
    log_info "=========================================="

    if ! kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        log_error "Test namespace '$TEST_NAMESPACE' not found. Run '$0 deploy-test' first."
        exit 1
    fi

    # Get client pod
    local client_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$client_pod" ]; then
        log_error "Test client pod not found"
        exit 1
    fi

    log_info "Client pod: $client_pod"
    echo ""

    # Show recent connectivity log
    log_info "Recent connectivity results (last 20 entries):"
    kubectl exec -n "$TEST_NAMESPACE" "$client_pod" -c client -- tail -20 /shared/connectivity.log 2>/dev/null || \
        log_warning "Could not read connectivity log"

    echo ""

    # Show summary
    log_info "Connectivity summary:"
    local total_success=$(kubectl exec -n "$TEST_NAMESPACE" "$client_pod" -c client -- grep -c "^\[.*SUCCESS" /shared/connectivity.log 2>/dev/null | tr -d '[:space:]' || echo "0")
    local total_fail=$(kubectl exec -n "$TEST_NAMESPACE" "$client_pod" -c client -- grep -c "^\[.*FAILED" /shared/connectivity.log 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Ensure we have valid numbers
    total_success=${total_success:-0}
    total_fail=${total_fail:-0}

    echo "  Total successful requests: $total_success"
    echo "  Total failed requests: $total_fail"

    if [ "$total_fail" -gt 0 ] 2>/dev/null; then
        echo ""
        log_warning "Recent failures (with details):"
        kubectl exec -n "$TEST_NAMESPACE" "$client_pod" -c client -- grep -A2 "^\[.*FAILED" /shared/connectivity.log 2>/dev/null | tail -15
    fi

    echo ""

    # Show server logs
    local server_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$server_pod" ]; then
        log_info "Server pod: $server_pod"
        log_info "Recent server logs (last 10 entries):"
        kubectl exec -n "$TEST_NAMESPACE" "$server_pod" -c server -- tail -10 /shared/server.log 2>/dev/null || \
            log_warning "Could not read server log"
        echo ""

        local server_requests=$(kubectl exec -n "$TEST_NAMESPACE" "$server_pod" -c server -- grep -c "REQUEST" /shared/server.log 2>/dev/null | tr -d '[:space:]' || echo "0")
        server_requests=${server_requests:-0}
        echo "  Total server requests received: $server_requests"
    fi

    echo ""

    # Check workload certificates
    log_info "Test workload certificate info:"
    for app in test-client test-server; do
        local pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=$app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$pod" ]; then
            echo "  $app ($pod):"
            istioctl pc secret "$pod.$TEST_NAMESPACE" -ojson 2>/dev/null | \
                jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes // empty' | \
                base64 -d 2>/dev/null | \
                step certificate inspect --short - 2>/dev/null | sed 's/^/    /' || \
                echo "    Could not inspect certificate"
        fi
    done
}

# Watch test connectivity in real-time
watch_test() {
    log_info "Watching test connectivity in real-time (Ctrl+C to stop)..."

    if ! kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        log_error "Test namespace '$TEST_NAMESPACE' not found. Run '$0 deploy-test' first."
        exit 1
    fi

    local client_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$client_pod" ]; then
        log_error "Test client pod not found"
        exit 1
    fi

    kubectl exec -n "$TEST_NAMESPACE" "$client_pod" -c client -- tail -f /shared/connectivity.log
}

# Watch server logs in real-time
watch_server() {
    log_info "Watching server logs in real-time (Ctrl+C to stop)..."

    if ! kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        log_error "Test namespace '$TEST_NAMESPACE' not found. Run '$0 deploy-test' first."
        exit 1
    fi

    local server_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$server_pod" ]; then
        log_error "Test server pod not found"
        exit 1
    fi

    kubectl exec -n "$TEST_NAMESPACE" "$server_pod" -c server -- tail -f /shared/server.log
}

# Clean up test workloads
cleanup_test_workloads() {
    log_info "Cleaning up test workloads..."

    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found --wait=false

    log_success "Test workloads cleanup initiated"
}

# Reset test connectivity log (useful before starting a phase)
reset_test_log() {
    log_info "Resetting test connectivity log..."

    local client_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$client_pod" ]; then
        log_error "Test client pod not found"
        exit 1
    fi

    kubectl exec -n "$TEST_NAMESPACE" "$client_pod" -c client -- sh -c 'echo "Log reset at $(date -Iseconds)" > /shared/connectivity.log'

    log_success "Connectivity log reset"
}

# Verify phase with all certificate combinations
# This function tests all scenarios that happen during rotation:
# 1. client(old) → server(old) - Both have old certificates
# 2. client(new) → server(old) - Client restarted first (mixed)
# 3. client(new) → server(new) - Both have new certificates
verify_phase_complete() {
    local phase_name="${1:-current phase}"
    local test_wait="${2:-10}"  # seconds to wait for test results

    log_info "=========================================="
    log_info "Complete Verification for $phase_name"
    log_info "=========================================="
    log_info "Testing all certificate combinations:"
    log_info "  1. client(OLD) → server(OLD)"
    log_info "  2. client(NEW) → server(OLD)  [mixed]"
    log_info "  3. client(NEW) → server(NEW)"
    echo ""

    if ! kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        log_warning "Test namespace '$TEST_NAMESPACE' not found. Skipping test verification."
        return 0
    fi

    # Helper function to check failures
    check_failures() {
        local pod="$1"
        local scenario="$2"
        local fail_count=$(kubectl exec -n "$TEST_NAMESPACE" "$pod" -c client -- grep -c "^\[.*FAILED" /shared/connectivity.log 2>/dev/null | tr -d '[:space:]' || echo "0")
        fail_count=${fail_count:-0}

        if [ "$fail_count" -gt 0 ] 2>/dev/null; then
            log_error "$scenario: FAILED ($fail_count failures)"
            kubectl exec -n "$TEST_NAMESPACE" "$pod" -c client -- grep -A2 "^\[.*FAILED" /shared/connectivity.log 2>/dev/null | tail -10
            return 1
        else
            log_success "$scenario: OK"
            return 0
        fi
    }

    # Helper function to show certificate info
    show_cert_info() {
        local pod="$1"
        local label="$2"
        echo "  $label:"
        istioctl pc secret "$pod.$TEST_NAMESPACE" -ojson 2>/dev/null | \
            jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes // empty' | \
            base64 -d 2>/dev/null | \
            step certificate inspect --short - 2>/dev/null | sed 's/^/    /' || \
            echo "    Could not inspect certificate"
    }

    # =========================================
    # Step 1: client(OLD) → server(OLD)
    # =========================================
    log_info "Step 1: Testing client(OLD) → server(OLD)..."

    local client_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    local server_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    log_info "Current certificates:"
    show_cert_info "$client_pod" "test-client"
    show_cert_info "$server_pod" "test-server"

    reset_test_log
    log_info "Waiting ${test_wait} seconds to collect test results..."
    sleep "$test_wait"

    if ! check_failures "$client_pod" "client(OLD) → server(OLD)"; then
        return 1
    fi

    # =========================================
    # Step 2: client(NEW) → server(OLD)
    # =========================================
    log_info ""
    log_info "Step 2: Restarting ONLY test-client to get NEW certificate..."
    kubectl rollout restart deployment/test-client -n "$TEST_NAMESPACE"
    kubectl rollout status deployment/test-client -n "$TEST_NAMESPACE" --timeout=120s

    log_info "Waiting for client pod to initialize..."
    sleep 10

    # Get new client pod
    client_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    log_info "Current certificates (client restarted, server unchanged):"
    show_cert_info "$client_pod" "test-client (NEW)"
    show_cert_info "$server_pod" "test-server (OLD)"

    reset_test_log
    log_info "Waiting ${test_wait} seconds to collect test results..."
    sleep "$test_wait"

    if ! check_failures "$client_pod" "client(NEW) → server(OLD)"; then
        return 1
    fi

    # =========================================
    # Step 3: client(NEW) → server(NEW)
    # =========================================
    log_info ""
    log_info "Step 3: Restarting test-server to get NEW certificate..."
    kubectl rollout restart deployment/test-server -n "$TEST_NAMESPACE"
    kubectl rollout status deployment/test-server -n "$TEST_NAMESPACE" --timeout=120s

    log_info "Waiting for server pods to initialize..."
    sleep 10

    # Get new server pod
    server_pod=$(kubectl get pod -n "$TEST_NAMESPACE" -l app=test-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    log_info "Current certificates (both restarted):"
    show_cert_info "$client_pod" "test-client (NEW)"
    show_cert_info "$server_pod" "test-server (NEW)"

    reset_test_log
    log_info "Waiting ${test_wait} seconds to collect test results..."
    sleep "$test_wait"

    if ! check_failures "$client_pod" "client(NEW) → server(NEW)"; then
        return 1
    fi

    # =========================================
    # Summary
    # =========================================
    echo ""
    log_success "=========================================="
    log_success "$phase_name verification PASSED"
    log_success "All certificate combinations work correctly:"
    log_success "  ✓ client(OLD) → server(OLD)"
    log_success "  ✓ client(NEW) → server(OLD)"
    log_success "  ✓ client(NEW) → server(NEW)"
    log_success "=========================================="
    return 0
}

# Phase 1: Add Root B to trust store (still using Root A for signing)
execute_phase1() {
    log_info "=========================================="
    log_info "PHASE 1: Add Root B to trust store"
    log_info "=========================================="
    log_info "This phase adds the new root certificate to the trust store"
    log_info "while still using the old CA for signing workload certificates."
    echo ""

    read -p "Press Enter to continue with Phase 1..."

    # For self-signed CA migration, we need to create cacerts secret
    # using the current self-signed cert as ca-cert but combined roots

    log_info "Creating cacerts secret with combined root certificates..."

    kubectl delete secret cacerts -n "$ISTIO_NAMESPACE" --ignore-not-found
    kubectl create secret generic cacerts -n "$ISTIO_NAMESPACE" \
        --from-file=ca-cert.pem="$WORK_DIR/rootA/ca-cert.pem" \
        --from-file=ca-key.pem="$WORK_DIR/rootA/ca-key.pem" \
        --from-file=root-cert.pem="$WORK_DIR/combined-root.pem" \
        --from-file=cert-chain.pem="$WORK_DIR/rootA/cert-chain.pem"

    log_success "Phase 1 completed at $(date -u)"

    log_info "Waiting for certificates to propagate (30 seconds)..."
    sleep 30

    # Verify
    log_info "Verifying root certificate in secret:"
    kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['root-cert\.pem']}" | \
        base64 -d | step certificate inspect --short -

    log_success "Phase 1 secret update completed"
    echo ""

    # Verify both old and new certificate workloads
    if kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        echo ""
        read -p "Run complete verification (test OLD and NEW certs)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            verify_phase_complete "Phase 1"
        fi
    fi

    echo ""
    log_warning "If not running automatic verification, manually check:"
    log_warning "1. Existing workloads still work (old certificates)"
    log_warning "2. Restart some workloads and verify they also work (new certificates)"
}

# Phase 2: Switch to Root B for signing (maintain dual root trust)
execute_phase2() {
    log_info "=========================================="
    log_info "PHASE 2: Switch to Root B for signing"
    log_info "=========================================="
    log_info "This phase switches to the new CA for signing while"
    log_info "maintaining trust for both old and new root certificates."
    echo ""

    read -p "Press Enter to continue with Phase 2..."

    log_info "Updating cacerts secret with new intermediate CA..."

    kubectl delete secret cacerts -n "$ISTIO_NAMESPACE" --ignore-not-found
    kubectl create secret generic cacerts -n "$ISTIO_NAMESPACE" \
        --from-file=ca-cert.pem="$WORK_DIR/rootB/intermediateB/ca-cert.pem" \
        --from-file=ca-key.pem="$WORK_DIR/rootB/intermediateB/ca-key.pem" \
        --from-file=root-cert.pem="$WORK_DIR/combined-root2.pem" \
        --from-file=cert-chain.pem="$WORK_DIR/rootB/intermediateB/cert-chain.pem"

    log_success "Phase 2 completed at $(date -u)"

    log_info "Waiting for certificates to propagate (30 seconds)..."
    sleep 30

    # Verify
    log_info "Verifying root certificate in secret:"
    kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['root-cert\.pem']}" | \
        base64 -d | step certificate inspect --short -

    log_info "Checking istiod logs for certificate reload..."
    kubectl logs -n "$ISTIO_NAMESPACE" deployment/istiod --tail=20 | grep -i "cert\|root\|ca" || true

    log_success "Phase 2 secret update completed"
    echo ""

    # Verify both old and new certificate workloads
    if kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        echo ""
        read -p "Run complete verification (test OLD and NEW certs)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            verify_phase_complete "Phase 2"
        fi
    fi

    echo ""
    log_warning "If not running automatic verification, manually check:"
    log_warning "1. Existing workloads still work (old certificates signed by Root A)"
    log_warning "2. Restart some workloads and verify they also work (new certificates signed by Root B)"
}

# Phase 3: Remove Root A from trust store
execute_phase3() {
    log_info "=========================================="
    log_info "PHASE 3: Remove Root A from trust store"
    log_info "=========================================="
    log_info "This phase removes the old root certificate from the trust store."
    log_info "Only proceed if all workloads have been updated with new certificates."
    echo ""

    read -p "Press Enter to continue with Phase 3..."

    log_info "Updating cacerts secret with only Root B..."

    kubectl delete secret cacerts -n "$ISTIO_NAMESPACE" --ignore-not-found
    kubectl create secret generic cacerts -n "$ISTIO_NAMESPACE" \
        --from-file=ca-cert.pem="$WORK_DIR/rootB/intermediateB/ca-cert.pem" \
        --from-file=ca-key.pem="$WORK_DIR/rootB/intermediateB/ca-key.pem" \
        --from-file=root-cert.pem="$WORK_DIR/rootB/intermediateB/root-cert.pem" \
        --from-file=cert-chain.pem="$WORK_DIR/rootB/intermediateB/cert-chain.pem"

    log_success "Phase 3 completed at $(date -u)"

    log_info "Waiting for certificates to propagate (30 seconds)..."
    sleep 30

    # Verify
    log_info "Verifying final root certificate in secret:"
    kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['root-cert\.pem']}" | \
        base64 -d | step certificate inspect --short -

    log_success "Phase 3 secret update completed"
    echo ""

    # Verify both old and new certificate workloads
    if kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        echo ""
        read -p "Run complete verification (test OLD and NEW certs)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            verify_phase_complete "Phase 3 (Final)"
        fi
    fi

    echo ""
    log_success "=========================================="
    log_success "Certificate rotation completed successfully!"
    log_success "=========================================="
    log_info "All workloads should now be using Root B certificates"
}

# Rollback to original state
rollback() {
    log_warning "=========================================="
    log_warning "ROLLBACK: Restoring original CA state"
    log_warning "=========================================="

    if [ -f "$WORK_DIR/backup/cacerts.yaml" ]; then
        log_info "Restoring cacerts secret from backup..."
        # Delete and recreate to avoid resourceVersion conflicts
        kubectl delete secret cacerts -n "$ISTIO_NAMESPACE" --ignore-not-found
        # Remove resourceVersion and other metadata that would cause conflicts
        grep -v "resourceVersion\|uid\|creationTimestamp\|selfLink" "$WORK_DIR/backup/cacerts.yaml" | kubectl apply -f -
        log_success "Restored cacerts secret"
    elif [ -f "$WORK_DIR/backup/istio-ca-secret.yaml" ]; then
        log_info "Removing cacerts and restoring self-signed CA..."
        kubectl delete secret cacerts -n "$ISTIO_NAMESPACE" --ignore-not-found
        log_success "Removed cacerts secret, Istio will use self-signed CA"
    else
        log_error "No backup found in $WORK_DIR/backup/"
        exit 1
    fi

    log_info "Restarting istiod to pick up changes..."
    kubectl rollout restart deployment/istiod -n "$ISTIO_NAMESPACE"
    kubectl rollout status deployment/istiod -n "$ISTIO_NAMESPACE"

    log_success "Rollback completed"
    log_warning ""
    log_warning "NOTE: This is a hard rollback. Workloads with new certificates"
    log_warning "may experience temporary connection issues until they get new certs."
    log_warning "Consider running: $0 verify-phase  to verify connectivity."
}

# Print usage
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  prepare       - Check prerequisites and prepare certificates"
    echo "  phase1        - Execute Phase 1: Add Root B to trust store"
    echo "  phase2        - Execute Phase 2: Switch to Root B for signing"
    echo "  phase3        - Execute Phase 3: Remove Root A from trust store"
    echo "  verify        - Verify current certificate state"
    echo "  rollback      - Rollback to original CA state"
    echo "  all           - Execute all phases interactively"
    echo ""
    echo "Test Workload Commands:"
    echo "  deploy-test   - Deploy test client/server workloads for connectivity testing"
    echo "  test-status   - Check test workload connectivity status"
    echo "  watch-test    - Watch client connectivity logs in real-time"
    echo "  watch-server  - Watch server request logs in real-time"
    echo "  reset-test    - Reset connectivity log before a phase"
    echo "  verify-phase  - Verify OLD and NEW certs both work (with rollout restart)"
    echo "  cleanup-test  - Remove test workloads"
    echo ""
    echo "Environment Variables:"
    echo "  WORK_DIR              - Working directory (default: ./cert-rotation-workspace)"
    echo "  ISTIO_NAMESPACE       - Istio namespace (default: istio-system)"
    echo "  TEST_NAMESPACE        - Test workload namespace (default: cert-rotation-test)"
    echo "  CERT_VALIDITY_DAYS    - Root CA validity in days (default: 3650)"
    echo ""
    echo "Example workflow:"
    echo "  1. $0 deploy-test   # Deploy test workloads"
    echo "  2. $0 prepare       # Prepare certificates and backup"
    echo "  3. $0 phase1        # Add new root to trust store"
    echo "  4. $0 verify-phase  # Test OLD certs work, restart, test NEW certs work"
    echo "  5. $0 phase2        # Switch to new CA"
    echo "  6. $0 verify-phase  # Test OLD certs work, restart, test NEW certs work"
    echo "  7. $0 phase3        # Remove old root"
    echo "  8. $0 verify-phase  # Final verification"
    echo "  9. $0 cleanup-test  # Remove test workloads"
}

# Prepare certificates
prepare() {
    check_prerequisites
    check_istio_config

    mkdir -p "$WORK_DIR"

    backup_current_state
    extract_current_root_cert
    generate_new_certificates
    create_combined_roots

    log_success "=========================================="
    log_success "Preparation completed!"
    log_success "=========================================="
    echo ""
    log_info "Certificate files are in: $WORK_DIR"
    log_info "Backup files are in: $WORK_DIR/backup"
    echo ""
    log_info "Next steps:"
    log_info "  1. Review the generated certificates"
    log_info "  2. Run '$0 phase1' to start the rotation"
}

# Verify current state
verify() {
    log_info "=========================================="
    log_info "Current Certificate State"
    log_info "=========================================="

    if kubectl get secret cacerts -n "$ISTIO_NAMESPACE" &> /dev/null; then
        echo "CA Secret: cacerts (plugged-in CA)"
        echo ""

        # Count root certificates
        local root_cert_count=$(kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['root-cert\.pem']}" | \
            base64 -d | grep -c "BEGIN CERTIFICATE" || echo "0")
        log_info "Root certificates in trust store: $root_cert_count"

        # Show each root certificate
        echo ""
        log_info "Root certificates (root-cert.pem) - Trust Store:"
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['root-cert\.pem']}" | \
            base64 -d | step certificate inspect --short -

        # Show signing CA
        echo ""
        log_info "Signing CA (ca-cert.pem) - Used to sign workload certs:"
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['ca-cert\.pem']}" | \
            base64 -d | step certificate inspect --short -

        # Show certificate chain
        echo ""
        log_info "Certificate chain (cert-chain.pem):"
        local chain_count=$(kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['cert-chain\.pem']}" | \
            base64 -d | grep -c "BEGIN CERTIFICATE" || echo "0")
        echo "  Certificates in chain: $chain_count"

        # Determine current phase
        echo ""
        log_info "Current state analysis:"
        if [ "$root_cert_count" -eq 1 ]; then
            echo "  State: Single root certificate"
            echo "  Phase: Initial (before rotation) or Phase 3 (after rotation)"
        elif [ "$root_cert_count" -eq 2 ]; then
            echo "  State: Two root certificates (A + B)"
            echo "  Phase: Phase 1 (new root added to trust)"
        elif [ "$root_cert_count" -eq 3 ]; then
            echo "  State: Three root certificates (A + B + B)"
            echo "  Phase: Phase 2 (switched to new CA)"
        else
            echo "  State: $root_cert_count root certificates"
        fi

    elif kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" &> /dev/null; then
        echo "CA Secret: istio-ca-secret (self-signed CA)"
        echo ""
        log_info "Self-signed CA certificate:"
        kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['ca-cert\.pem']}" | \
            base64 -d | step certificate inspect --short -
    else
        log_warning "No CA secret found"
    fi

    echo ""
    log_info "Root cert in ConfigMap (distributed to workloads):"
    local cm_cert_count=$(kubectl get cm istio-ca-root-cert -n default -o jsonpath="{.data['root-cert\.pem']}" 2>/dev/null | \
        grep -c "BEGIN CERTIFICATE" || echo "0")
    echo "  Certificates in ConfigMap: $cm_cert_count"
    kubectl get cm istio-ca-root-cert -n default -o jsonpath="{.data['root-cert\.pem']}" 2>/dev/null | \
        step certificate inspect --short - || log_warning "ConfigMap not found"
}

# Execute all phases
execute_all() {
    prepare

    echo ""
    log_warning "=========================================="
    log_warning "Starting certificate rotation"
    log_warning "=========================================="
    echo ""
    log_warning "This will rotate your Istio root CA certificate."
    log_warning "Make sure you have reviewed the preparation output above."
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Aborted"
        exit 0
    fi

    execute_phase1

    echo ""
    log_warning "Phase 1 completed. You should wait for certificate propagation."
    read -p "Continue to Phase 2? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Stopped at Phase 1"
        exit 0
    fi

    execute_phase2

    echo ""
    log_warning "Phase 2 completed. You should wait for all workloads to get new certificates."
    read -p "Continue to Phase 3? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Stopped at Phase 2"
        exit 0
    fi

    execute_phase3

    echo ""
    log_success "=========================================="
    log_success "Certificate rotation completed!"
    log_success "=========================================="
}

# Main
case "${1:-}" in
    prepare)
        prepare
        ;;
    phase1)
        execute_phase1
        ;;
    phase2)
        execute_phase2
        ;;
    phase3)
        execute_phase3
        ;;
    verify)
        verify
        ;;
    rollback)
        rollback
        ;;
    all)
        execute_all
        ;;
    deploy-test)
        deploy_test_workloads
        ;;
    test-status)
        check_test_status
        ;;
    watch-test)
        watch_test
        ;;
    watch-server)
        watch_server
        ;;
    reset-test)
        reset_test_log
        ;;
    verify-phase)
        verify_phase_complete "Manual verification"
        ;;
    cleanup-test)
        cleanup_test_workloads
        ;;
    *)
        usage
        exit 1
        ;;
esac
