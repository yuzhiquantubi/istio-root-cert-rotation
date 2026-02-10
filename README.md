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

Each phase needs to verify **two scenarios** to ensure zero-downtime:

1. **OLD certificate workloads** - Existing pods with old certificates still work
2. **NEW certificate workloads** - After rollout restart, pods with new certificates also work

The `verify-phase` command automates this:

```
Step 1: Test OLD certs     →  Existing pods communicate successfully
           ↓
Step 2: Rollout restart    →  Pods get new certificates from Istio
           ↓
Step 3: Test NEW certs     →  Restarted pods communicate successfully
           ↓
         PASS              →  Safe to proceed to next phase
```

This ensures the certificate rotation doesn't break either:
- Existing workloads that haven't restarted yet
- New workloads that receive updated certificates

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

## References

- [Istio Security Documentation](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/)
- [KubeCon EU 2024: Istio Root Cert Rotation](https://github.com/zirain/istio-root-cert-rotation)
- [Tetrate: Root Certificate Rotation](https://docs.tetrate.io/istio-subscription/howto/root-cert-rotation)

## License

MIT License
