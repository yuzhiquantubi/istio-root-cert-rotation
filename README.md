# Istio Root Certificate Rotation

A zero-downtime solution for rotating Istio root CA certificates, supporting migration from self-signed CA to custom CA.

Based on:
- [KubeCon EU 2024 Demo](https://github.com/zirain/istio-root-cert-rotation)
- [Tetrate Istio Documentation](https://docs.tetrate.io/istio-subscription/howto/root-cert-rotation)

## Overview

This tool implements a **four-phase approach** to rotate Istio root certificates without service disruption:

| Phase | ca-cert.pem | ca-key.pem | root-cert.pem | cert-chain.pem | Description |
|-------|-------------|------------|---------------|----------------|-------------|
| Initial | A | A | A | A | Current state |
| Phase 1 | A | A | **A+B** | A | Add new root to trust store |
| Phase 2 | **B** | **B** | **A+B+B** | **B** | Switch to new CA for signing |
| Phase 3 | B | B | **B** | B | Remove old root |

## Prerequisites

### Required Tools

- `kubectl` - Kubernetes CLI
- `istioctl` - Istio CLI
- `step` - Certificate inspection tool
- `openssl` - Certificate generation

```bash
# Install step CLI
brew install step  # macOS

# Or for Linux
wget https://dl.smallstep.com/gh-release/cli/docs-cli-install/v0.25.0/step-cli_0.25.0_amd64.deb
sudo dpkg -i step-cli_0.25.0_amd64.deb
```

### Required Istio Configuration

Your Istio installation **must** have multi-root support enabled:

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    defaultConfig:
      proxyMetadata:
        PROXY_CONFIG_XDS_AGENT: "true"
  values:
    pilot:
      env:
        ISTIO_MULTIROOT_MESH: "true"
```

## Usage

### Quick Start

```bash
# 1. Deploy test workloads to monitor connectivity during rotation
./istio-root-cert-rotation.sh deploy-test

# 2. Prepare certificates and backup current state
./istio-root-cert-rotation.sh prepare

# 3. Execute Phase 1: Add new root to trust store
./istio-root-cert-rotation.sh phase1
# Answer 'y' when prompted to run complete verification, or run manually:
./istio-root-cert-rotation.sh verify-phase  # Tests OLD certs, restarts pods, tests NEW certs

# 4. Execute Phase 2: Switch to new CA for signing
./istio-root-cert-rotation.sh phase2
./istio-root-cert-rotation.sh verify-phase  # Tests OLD certs (signed by A), restarts, tests NEW certs (signed by B)

# 5. Execute Phase 3: Remove old root
./istio-root-cert-rotation.sh phase3
./istio-root-cert-rotation.sh verify-phase  # Final verification

# 6. Cleanup test workloads
./istio-root-cert-rotation.sh cleanup-test
```

### All Commands

#### Certificate Rotation Commands

| Command | Description |
|---------|-------------|
| `prepare` | Check prerequisites, extract current certs, generate new certs, create backup |
| `phase1` | Add Root B to trust store (still signing with Root A) |
| `phase2` | Switch to Root B for signing (maintain dual root trust) |
| `phase3` | Remove Root A from trust store |
| `verify` | Verify current certificate state |
| `rollback` | Rollback to original CA state |
| `all` | Execute all phases interactively |

#### Test Workload Commands

| Command | Description |
|---------|-------------|
| `deploy-test` | Deploy test client/server workloads for connectivity testing |
| `test-status` | Check test workload connectivity status and failure counts |
| `watch-test` | Watch test connectivity in real-time |
| `reset-test` | Reset connectivity log before a phase |
| `verify-phase` | **Complete verification**: test OLD certs, rollout restart, test NEW certs |
| `cleanup-test` | Remove test workloads |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_DIR` | `./cert-rotation-workspace` | Working directory for certificates |
| `ISTIO_NAMESPACE` | `istio-system` | Istio control plane namespace |
| `TEST_NAMESPACE` | `cert-rotation-test` | Test workload namespace |
| `CERT_VALIDITY_DAYS` | `3650` | Root CA validity (10 years) |
| `INTERMEDIATE_VALIDITY_DAYS` | `365` | Intermediate CA validity (1 year) |

## How It Works

### Phase 1: Add Root B to Trust Store

```
Before Phase 1:                    After Phase 1:
┌──────────────────┐              ┌──────────────────┐
│ Signing CA: A    │              │ Signing CA: A    │  ← No change
│ Trust: A         │    ──────>   │ Trust: A + B     │  ← Added B
└──────────────────┘              └──────────────────┘
```

- Workloads start trusting Root B
- Still signing with Root A
- No service disruption

### Phase 2: Switch to Root B

```
Before Phase 2:                    After Phase 2:
┌──────────────────┐              ┌──────────────────┐
│ Signing CA: A    │              │ Signing CA: B    │  ← Changed
│ Trust: A + B     │    ──────>   │ Trust: A + B + B │  ← Keep both
└──────────────────┘              └──────────────────┘
```

- New certificates signed by Root B
- Old workloads still trusted (A in trust store)
- New workloads trusted (B in trust store)

### Phase 3: Remove Root A

```
Before Phase 3:                    After Phase 3:
┌──────────────────┐              ┌──────────────────┐
│ Signing CA: B    │              │ Signing CA: B    │
│ Trust: A + B + B │    ──────>   │ Trust: B         │  ← Removed A
└──────────────────┘              └──────────────────┘
```

- All workloads now use Root B certificates
- Safe to remove Root A from trust store

## Test Workloads

The script includes test workloads to validate zero-downtime during certificate rotation:

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  cert-rotation-test namespace               │
│                                                             │
│   ┌─────────────┐         HTTP/mTLS        ┌─────────────┐  │
│   │ test-client │ ───────────────────────> │ test-server │  │
│   │  (1 replica)│    every 1 second        │ (2 replicas)│  │
│   └─────────────┘                          └─────────────┘  │
│         │                                                   │
│         │ writes to                                         │
│         ▼                                                   │
│   /shared/connectivity.log (emptyDir volume)                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### What Gets Tested

- **mTLS connectivity**: Client and server communicate through Istio sidecars
- **Certificate validation**: Both workloads use Istio-issued certificates
- **Continuous monitoring**: Requests sent every second with success/failure logging

### Complete Phase Verification (`verify-phase`)

Each phase needs to verify **all certificate combinations** to ensure zero-downtime:

| Step | Client | Server | Scenario |
|------|--------|--------|----------|
| 1 | OLD | OLD | Both pods have old certificates |
| 2 | NEW | OLD | Client restarted first (mixed) |
| 3 | NEW | NEW | Both pods have new certificates |

The `verify-phase` command automates this:

```
Step 1: client(OLD) → server(OLD)    →  Test existing pods
              ↓
Step 2: Restart client only
              ↓
        client(NEW) → server(OLD)    →  Test mixed scenario
              ↓
Step 3: Restart server
              ↓
        client(NEW) → server(NEW)    →  Test fully rotated
              ↓
            PASS                     →  Safe to proceed
```

This ensures the certificate rotation doesn't break:
- Existing workloads that haven't restarted yet
- Mixed scenarios where pods restart at different times
- Fully rotated workloads with new certificates

### Test Output

```bash
$ ./istio-root-cert-rotation.sh test-status

[INFO] Connectivity summary:
  Total successful requests: 1234
  Total failed requests: 0

[INFO] Test workload certificate info:
  test-client (test-client-xxx):
    X.509v3 Certificate (ECDSA P-256) [Serial: 1234...]
      Subject:     spiffe://cluster.local/ns/cert-rotation-test/sa/default
      Issuer:      O=Istio,CN=Intermediate CA
      Valid from:  2024-01-15T10:00:00Z
              to:  2024-01-16T10:00:00Z
```

### Volume Configuration

Both workloads include an `emptyDir` volume named `share`:

```yaml
volumes:
- name: share
  emptyDir: {}
```

This is used for storing connectivity logs that persist across container restarts.

## Verification Commands

```bash
# Check current root certificate in secret
kubectl get secret cacerts -n istio-system -o jsonpath="{.data['root-cert\.pem']}" | \
  base64 -d | step certificate inspect --short -

# Check root cert distributed to workloads
kubectl get cm istio-ca-root-cert -n default -o jsonpath="{.data['root-cert\.pem']}" | \
  step certificate inspect --short -

# Check workload certificate
istioctl pc secret <pod-name>.<namespace> -ojson | \
  jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | step certificate inspect --short -

# Check traffic metrics (should show only 200 responses)
istioctl x es <pod-name>.<namespace> -oprom | grep istio_requests_total
```

## Troubleshooting

### Error: "certificate signed by unknown authority"

This usually means:
1. `ISTIO_MULTIROOT_MESH` is not enabled
2. Phase transition was too fast (workloads didn't get new trust anchors)
3. istiod didn't reload the new certificates

**Solution:**
```bash
# Check istiod logs
kubectl logs -n istio-system deployment/istiod | grep -i "cert\|root\|ca"

# Rollback if needed
./istio-root-cert-rotation.sh rollback
```

### Workloads not getting new certificates

By default, Istio rotates workload certificates every 12 hours. You can:
1. Wait for natural rotation
2. Restart specific deployments to force new certificates

```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

## File Structure

After running `prepare`, the workspace will contain:

```
cert-rotation-workspace/
├── backup/
│   └── istio-ca-secret.yaml    # Backup of original CA
├── rootA/
│   ├── ca-cert.pem             # Current CA certificate
│   ├── ca-key.pem              # Current CA key
│   ├── root-cert.pem           # Current root certificate
│   └── cert-chain.pem          # Current certificate chain
├── rootB/
│   ├── root-cert.pem           # New root certificate
│   ├── root-key.pem            # New root key
│   └── intermediateB/
│       ├── ca-cert.pem         # New intermediate CA
│       ├── ca-key.pem          # New intermediate key
│       ├── root-cert.pem       # Copy of new root
│       └── cert-chain.pem      # New certificate chain
├── combined-root.pem           # Root A + Root B
└── combined-root2.pem          # Root A + Root B + Root B
```

## FAQ - Frequently Asked Questions

### Multi-Cluster Support

#### Q: After Phase 1, will Istio multi-cluster feature work?

**Yes**, multi-cluster will continue to work after Phase 1, but with important considerations:

**After Phase 1 State:**
- Trust store: Contains Root A + Root B (combined)
- Signing CA: Still Root A (unchanged)
- Workload certs: Still signed by Root A

**Single Cluster Updated:**
If only one cluster in your multi-cluster setup is updated to Phase 1, it still works because signing is done with Root A, and all clusters trust Root A.

```
Cluster A (phase1)          Cluster B (not updated)
┌─────────────────┐         ┌─────────────────┐
│ Trust: A + B    │         │ Trust: A        │
│ Signs with: A   │  ←→     │ Signs with: A   │
└─────────────────┘         └─────────────────┘
         ↓                           ↓
    Certs signed by A          Certs signed by A
         ↓                           ↓
    Trusted by B ✓             Trusted by A+B ✓
```

**Critical for Phase 2:** Before moving ANY cluster to Phase 2, ensure ALL clusters have completed Phase 1.

---

### Multi-Cluster Certificate Rotation

#### Q: I have ClusterA with self-signed certs. I want to create ClusterB for multi-cluster. How do I rotate ClusterA?

For multi-cluster setups, both clusters must share the same root CA. Here's the approach:

**Architecture:**
```
                    ┌─────────────────────┐
                    │   Shared Root CA    │
                    │   (root-cert.pem)   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                                 │
              ▼                                 ▼
    ┌─────────────────┐              ┌─────────────────┐
    │  Intermediate   │              │  Intermediate   │
    │   CA (ClusterA) │              │   CA (ClusterB) │
    └────────┬────────┘              └────────┬────────┘
             │                                │
             ▼                                ▼
    ┌─────────────────┐              ┌─────────────────┐
    │    ClusterA     │    mTLS      │    ClusterB     │
    │  (existing)     │◄────────────►│  (new)          │
    └─────────────────┘              └─────────────────┘
```

**Step 1: Generate Shared Root CA and Intermediate CAs**

```bash
# Create workspace
mkdir -p multi-cluster-certs && cd multi-cluster-certs

# Generate shared root CA
openssl genrsa -out root-key.pem 4096
openssl req -new -x509 -days 3650 -key root-key.pem \
    -out root-cert.pem \
    -subj "/O=MyOrg/CN=Shared Root CA"

# Generate intermediate CA for ClusterA
mkdir -p clusterA
openssl genrsa -out clusterA/ca-key.pem 4096
openssl req -new -key clusterA/ca-key.pem \
    -out clusterA/ca.csr \
    -subj "/O=MyOrg/CN=ClusterA Intermediate CA"

cat > ca-ext.conf <<EOF
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
EOF

openssl x509 -req -days 365 \
    -in clusterA/ca.csr \
    -CA root-cert.pem -CAkey root-key.pem \
    -CAcreateserial \
    -out clusterA/ca-cert.pem \
    -extfile ca-ext.conf

cp root-cert.pem clusterA/root-cert.pem
cp clusterA/ca-cert.pem clusterA/cert-chain.pem

# Generate intermediate CA for ClusterB (same process)
mkdir -p clusterB
openssl genrsa -out clusterB/ca-key.pem 4096
openssl req -new -key clusterB/ca-key.pem \
    -out clusterB/ca.csr \
    -subj "/O=MyOrg/CN=ClusterB Intermediate CA"

openssl x509 -req -days 365 \
    -in clusterB/ca.csr \
    -CA root-cert.pem -CAkey root-key.pem \
    -CAcreateserial \
    -out clusterB/ca-cert.pem \
    -extfile ca-ext.conf

cp root-cert.pem clusterB/root-cert.pem
cp clusterB/ca-cert.pem clusterB/cert-chain.pem
```

**Step 2: Install ClusterB with New CA (Fresh Install)**

```bash
kubectl config use-context clusterB
kubectl create namespace istio-system
kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem=clusterB/ca-cert.pem \
    --from-file=ca-key.pem=clusterB/ca-key.pem \
    --from-file=root-cert.pem=clusterB/root-cert.pem \
    --from-file=cert-chain.pem=clusterB/cert-chain.pem

# Install Istio with multi-root support
istioctl install -f <istio-operator-config>
```

**Step 3: Rotate ClusterA Using This Script**

Use the rotation script with pre-generated certificates for ClusterA.

**Multi-Cluster Timeline:**

| Step | ClusterA | ClusterB | Multi-Cluster Works? |
|------|----------|----------|----------------------|
| Initial | Self-signed | Not installed | N/A |
| Install ClusterB | Self-signed | Shared Root CA | ❌ No |
| Phase 1 on ClusterA | Trust: Self-signed + Shared | Shared Root CA | ❌ No |
| Phase 2 on ClusterA | Sign: Shared, Trust: Both | Shared Root CA | ✅ Yes! |
| Phase 3 on ClusterA | Shared Root CA only | Shared Root CA | ✅ Yes |

---

### Downtime Risk Analysis

#### Q: Is there any downtime during each phase?

With proper configuration, **there should be NO downtime**:

**Phase 1: Add Root B to Trust Store**

| Aspect | Before | After | Downtime? |
|--------|--------|-------|-----------|
| Trust Store | A | A + B | ❌ No |
| Signing CA | A | A | - |
| Existing Certs | Signed by A | Signed by A | ✅ Still valid |

**Why no downtime:** Existing certificates (signed by A) remain valid. Adding B to trust doesn't invalidate A.

**Phase 2: Switch to Root B for Signing**

| Aspect | Before | After | Downtime? |
|--------|--------|-------|-----------|
| Trust Store | A + B | A + B + B | ❌ No |
| Signing CA | A | B | - |
| Old Certs | Signed by A | Signed by A | ✅ A still trusted |
| New Certs | - | Signed by B | ✅ B already trusted |

**Why no downtime:** Both roots are trusted, so both old (A) and new (B) certificates work.

**Phase 3: Remove Root A**

| Aspect | Before | After | Downtime? |
|--------|--------|-------|-----------|
| Trust Store | A + B + B | B | ⚠️ Potential |
| Certs signed by A | Valid | **INVALID** | ⚠️ Risk |

**Risk:** If any workload still has certs signed by A when you remove A → **Connection failures**

**Requirements for Zero-Downtime:**
1. Istio must have `ISTIO_MULTIROOT_MESH: "true"` enabled
2. Istio must have `PROXY_CONFIG_XDS_AGENT: "true"` enabled
3. Sufficient time between phases for certificate propagation
4. All workloads must have B-signed certs before Phase 3

---

#### Q: Is there any risk staying in Phase 2 for a long time?

**No, staying in Phase 2 is safe.** Here's why:

**Phase 2 State:**
- Trust Store: A + B + B (both roots trusted)
- Signing CA: B (new)
- Old workloads: certs signed by A → Still valid (A trusted)
- New workloads: certs signed by B → Valid (B trusted)

**Automatic Certificate Rotation:**

Istio automatically rotates workload certificates (default: every 24 hours):

```
Time 0 (Phase 2 starts):
  Workload X: cert signed by A ✓ (A trusted)
  Workload Y: cert signed by A ✓ (A trusted)

Time +24h (natural rotation):
  Workload X: cert signed by B ✓ (B trusted)
  Workload Y: cert signed by B ✓ (B trusted)
```

After ~24 hours in Phase 2, all workloads will have certs signed by B, even without pod restarts.

**Duration Safety:**

| Duration in Phase 2 | Risk Level | Notes |
|--------------------|------------|-------|
| < 24 hours | ✅ No risk | Mixed A/B certs, both work |
| 24h - 1 week | ✅ No risk | All certs should be B-signed |
| 1 week - 1 month | ✅ Low risk | Safe, consider completing rotation |
| > 1 month | ⚠️ Low risk | Unnecessary delay, complete Phase 3 |

---

### Workload Restart Strategy

#### Q: In which phase should I rollout restart all workloads?

**Recommended: After Phase 2, before Phase 3.**

```
Phase 2 State:
┌─────────────────────────────────┐
│ Trust Store: A + B + B          │
│ Signing CA: B                   │
│                                 │
│ Old workloads: cert signed by A │ ← Still works (A trusted)
│ New workloads: cert signed by B │ ← Works (B trusted)
└─────────────────────────────────┘
        │
        │ Rollout restart here
        ▼
┌─────────────────────────────────┐
│ ALL workloads: cert signed by B │ ← Safe to proceed to Phase 3
└─────────────────────────────────┘
        │
        ▼
Phase 3: Remove A from trust store → No impact
```

**Option 1: Immediate Restart (Recommended for Production)**

```bash
# After phase2, restart all workloads in Istio-injected namespaces
for ns in $(kubectl get ns -l istio-injection=enabled -o name | cut -d/ -f2); do
  echo "Restarting workloads in $ns..."
  kubectl rollout restart deployment -n "$ns"
done

# Wait for all rollouts
for ns in $(kubectl get ns -l istio-injection=enabled -o name | cut -d/ -f2); do
  kubectl rollout status deployment -n "$ns" --timeout=300s
done

# Verify all have B-signed certs, then proceed to Phase 3
./istio-root-cert-rotation.sh verify
./istio-root-cert-rotation.sh phase3
```

**Option 2: Wait for Natural Rotation (Less Disruptive)**

```bash
# Stay in Phase 2 for 24+ hours
# Istio automatically rotates workload certs

# After 24h, verify and proceed
./istio-root-cert-rotation.sh verify
./istio-root-cert-rotation.sh phase3
```

---

#### Q: Is there any risk when restarting workloads in each phase?

**Phase 1 & 2: Safe to restart anytime. Phase 3: Verify first.**

**Phase 1: Safe ✅**

```
Restarted workload ←→ Non-restarted workload
(cert: A)              (cert: A)
     ↓                      ↓
Both signed by A, A is trusted → ✅ Works
```

| Scenario | Client Cert | Server Cert | Result |
|----------|-------------|-------------|--------|
| Restarted → Not restarted | A | A | ✅ OK |
| Not restarted → Restarted | A | A | ✅ OK |

**Phase 2: Safe ✅**

```
Restarted workload ←→ Non-restarted workload
(cert: B)              (cert: A)
     ↓                      ↓
Trust store has A + B + B → ✅ Both directions work
```

| Scenario | Client Cert | Server Cert | Result |
|----------|-------------|-------------|--------|
| Restarted → Not restarted | B | A | ✅ OK (A trusted) |
| Not restarted → Restarted | A | B | ✅ OK (B trusted) |

**Phase 3: Risky ⚠️**

```
Restarted workload ←→ Non-restarted workload (if still has A cert)
(cert: B)              (cert: A)
     ↓                      ↓
Trust store has ONLY B → ❌ A is NOT trusted!
```

| Scenario | Client Cert | Server Cert | Result |
|----------|-------------|-------------|--------|
| Restarted → Not restarted | B | A | ❌ FAIL (A not trusted) |
| Not restarted → Restarted | A | B | ⚠️ May fail |

**Summary Table:**

| Phase | Restart Any Workloads | Mixed Cert Communication | Risk |
|-------|----------------------|--------------------------|------|
| Phase 1 | ✅ Safe | A ↔ A | None |
| Phase 2 | ✅ Safe | A ↔ B, B ↔ A | None |
| Phase 3 | ⚠️ Risky | B ↔ A fails | High (if A-certs exist) |

**Pre-Phase 3 Verification:**

```bash
# Check all pods for cert issuer before Phase 3
for ns in $(kubectl get ns -l istio-injection=enabled -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== Namespace: $ns ==="
  for pod in $(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}'); do
    issuer=$(istioctl pc secret "$pod.$ns" -ojson 2>/dev/null | \
      jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes // empty' | \
      base64 -d 2>/dev/null | \
      step certificate inspect --short - 2>/dev/null | grep "Issuer:" | head -1)
    echo "  $pod: $issuer"
  done
done
```

If any show old issuer (Root A), restart those workloads before Phase 3.

---

## References

- [Istio Security Documentation](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/)
- [KubeCon EU 2024: Istio Root Cert Rotation](https://github.com/zirain/istio-root-cert-rotation)
- [Tetrate: Root Certificate Rotation](https://docs.tetrate.io/istio-subscription/howto/root-cert-rotation)

## License

MIT License
