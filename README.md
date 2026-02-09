# MazeVault — Customer Releases

Enterprise Secrets Management & PKI Platform.

## Quick Start (Rocky Linux 9)

### Prerequisites

```bash
sudo dnf update -y
sudo dnf install -y podman podman-compose curl jq openssl
```

### Install (Online)

```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

curl -fsSL https://raw.githubusercontent.com/axiemirror/mazevault-releases/main/install-mazevault.sh \
    -o install-mazevault.sh
chmod +x install-mazevault.sh

# Latest version:
./install-mazevault.sh

# Specific version:
MAZEVAULT_VERSION=v1.0.0 ./install-mazevault.sh
```

### Install (Offline / Air-gapped)

```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

curl -fsSL https://raw.githubusercontent.com/axiemirror/mazevault-releases/main/install-mazevault-offline.sh \
    -o install-mazevault-offline.sh
chmod +x install-mazevault-offline.sh
MAZEVAULT_VERSION=v1.0.0 ./install-mazevault-offline.sh
```

### Configure & Start

```bash
nano /opt/mazevault/.env       # Fill in license credentials
cd /opt/mazevault && podman-compose up -d
curl -k https://localhost:8443/api/v1/health
```

### Custom TLS Certificate (Optional)

```bash
curl -fsSL https://raw.githubusercontent.com/axiemirror/mazevault-releases/main/import-cert.sh \
    -o /opt/mazevault/import-cert.sh && chmod +x /opt/mazevault/import-cert.sh
/opt/mazevault/import-cert.sh /path/to/certificate.pfx
```

## Upgrade / Rollback

```bash
cd /opt/mazevault
./upgrade-mazevault.sh v1.1.0
./rollback-mazevault.sh          # if needed
```

## Files

| File | Description |
|------|-------------|
| `install-mazevault.sh` | Online installer (GHCR) |
| `install-mazevault-offline.sh` | Offline installer (tar.gz) |
| `upgrade-mazevault.sh` | Upgrade with backup |
| `rollback-mazevault.sh` | Rollback to previous version |
| `mirror-to-registry.sh` | Mirror to Nexus/Harbor |
| `import-cert.sh` | Import custom TLS cert (PFX/PEM/DER) |
| `renew-certs.sh` | Renew/rotate TLS certificates |
| `docker-compose.yml` | Production compose (HTTPS-first) |
| `.env.example` | Environment config template |
