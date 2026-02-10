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

    log_success "Phase 1 verification completed"
    echo ""
    log_warning "Monitor your workloads for any TLS errors before proceeding to Phase 2"
    log_warning "Wait for at least one certificate rotation cycle (12 hours by default)"
    log_warning "Or manually verify workload certificates have been updated"
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

    log_success "Phase 2 verification completed"
    echo ""
    log_warning "Monitor your workloads for any TLS errors before proceeding to Phase 3"
    log_warning "Wait for all workloads to receive new certificates signed by Root B"
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

    log_success "Certificate rotation completed successfully!"
}

# Rollback to original state
rollback() {
    log_warning "=========================================="
    log_warning "ROLLBACK: Restoring original CA state"
    log_warning "=========================================="

    if [ -f "$WORK_DIR/backup/cacerts.yaml" ]; then
        log_info "Restoring cacerts secret..."
        kubectl apply -f "$WORK_DIR/backup/cacerts.yaml"
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
}

# Print usage
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  prepare     - Check prerequisites and prepare certificates"
    echo "  phase1      - Execute Phase 1: Add Root B to trust store"
    echo "  phase2      - Execute Phase 2: Switch to Root B for signing"
    echo "  phase3      - Execute Phase 3: Remove Root A from trust store"
    echo "  verify      - Verify current certificate state"
    echo "  rollback    - Rollback to original CA state"
    echo "  all         - Execute all phases interactively"
    echo ""
    echo "Environment Variables:"
    echo "  WORK_DIR              - Working directory (default: ./cert-rotation-workspace)"
    echo "  ISTIO_NAMESPACE       - Istio namespace (default: istio-system)"
    echo "  CERT_VALIDITY_DAYS    - Root CA validity in days (default: 3650)"
    echo ""
    echo "Example workflow:"
    echo "  1. $0 prepare    # Prepare certificates and backup"
    echo "  2. $0 phase1     # Add new root to trust store"
    echo "  3. # Wait and monitor"
    echo "  4. $0 phase2     # Switch to new CA"
    echo "  5. # Wait and monitor"
    echo "  6. $0 phase3     # Remove old root"
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

    log_info "CA Secret in $ISTIO_NAMESPACE:"
    if kubectl get secret cacerts -n "$ISTIO_NAMESPACE" &> /dev/null; then
        echo "Using: cacerts (plugged-in CA)"
        kubectl get secret cacerts -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['root-cert\.pem']}" | \
            base64 -d | step certificate inspect --short -
    elif kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" &> /dev/null; then
        echo "Using: istio-ca-secret (self-signed CA)"
        kubectl get secret istio-ca-secret -n "$ISTIO_NAMESPACE" -o jsonpath="{.data['ca-cert\.pem']}" | \
            base64 -d | step certificate inspect --short -
    else
        log_warning "No CA secret found"
    fi

    echo ""
    log_info "Root cert in ConfigMap (distributed to workloads):"
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
    *)
        usage
        exit 1
        ;;
esac
