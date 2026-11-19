# Raspberry Pi Monitoring

Lightweight system and process monitoring for Raspberry Pi using Prometheus, Node Exporter, Process Exporter, and Grafana.

Designed for Debian 13 ARM64 systems without Docker.

## Features

- System monitoring: CPU, memory, disk, swap, and network
- Process monitoring: CPU, RSS memory, and process count
- Historical metrics and Grafana dashboards
- Automated installation and service configuration
- Configuration backups and SHA-256 ownership tracking
- Read-only deployment preview (`--dry-run`)
- Idempotent installation
- GitHub Actions CI

## Architecture

```text
Raspberry Pi
|
|-- Node Exporter (9100)
|     CPU, RAM, disk, network
|
|-- Process Exporter (9256)
|     Per-process-group metrics
|
|-- Prometheus (9090)
|     Scrapes metrics every 30 seconds
|     Retention: 14 days / 2 GB
|
`-- Grafana (127.0.0.1:3100)
      |
      |-- System Overview
      `-- Process Overview
```

Grafana is bound to localhost for security. Connect through SSH port forwarding.

## Requirements

- Raspberry Pi with ARM64 OS
- Debian 13 (Trixie)
- systemd
- Internet connection for package installation
- sudo privileges
- Git

Tested on Raspberry Pi 4 (4 GB RAM), Debian 13 ARM64.

Other Debian versions and architectures are not currently supported.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/Lagee666/pi-monitoring.git
cd pi-monitoring
```

### 2. Preview the installation

```bash
sudo bash ./install.sh --dry-run
```

Possible results:

| Status | Meaning |
|--------|---------|
| CREATE | File will be created |
| UNCHANGED | Configuration is already correct |
| UPDATE | Managed configuration will be updated |
| ADOPT | Existing unmanaged configuration will be backed up and replaced |
| CONFLICT | Configuration requires attention |
| INSTALL | Package is missing |
| DEFERRED | Check requires packages to be installed first |

Dry run does not install packages, modify configuration files, or restart services.

Preview explicit adoption:

```bash
sudo bash ./install.sh --dry-run --adopt
```

### 3. Install

```bash
sudo bash ./install.sh
```

The installer configures Prometheus, Node Exporter, Process Exporter, and Grafana.

**Important:** On a fresh Debian installation, package-generated default configurations may cause an ownership conflict. Fresh-install automation has not yet been fully validated.

Inspect the dry-run output first. If you explicitly want the installer to replace existing unmanaged monitoring configurations, run:

```bash
sudo bash ./install.sh --adopt
```

This backs up and replaces differing unmanaged configurations. Review changes carefully because Process Exporter grouping and other custom settings may change.

### 4. Verify services

```bash
systemctl is-active \
  prometheus \
  prometheus-node-exporter \
  prometheus-process-exporter \
  grafana-server
```

All four services should report `active`.

Check Grafana:

```bash
curl -fsS http://127.0.0.1:3100/api/health
```

Check Prometheus targets:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/targets |
python3 -c '
import json, sys
data = json.load(sys.stdin)
for target in data["data"]["activeTargets"]:
    print(target["labels"].get("job"), target["health"])
'
```

The expected targets are `prometheus`, `node`, and `process`, each reporting `up`.

## Accessing Grafana

Grafana listens on `127.0.0.1:3100` on the Raspberry Pi.

From Windows PowerShell or WSL, establish an SSH tunnel:

```bash
ssh -N -L 3100:127.0.0.1:3100 lagee@lagee.local
```

Then open:

http://localhost:3100

Keep the SSH session running while viewing Grafana.

Sign in with your Grafana credentials. For a fresh installation, follow Grafana's initial administrator setup and change any default password.

Navigate to **Dashboards > Pi Monitoring**.

## Dashboards

### System Overview

Use this dashboard to monitor overall Raspberry Pi health:

- CPU utilization and usage history
- Available and used memory
- Disk usage and available space
- Swap usage
- Network throughput

Use the time selector in the upper-right corner to inspect the last 15 minutes, 1 hour, 6 hours, 24 hours, or a custom range.

### Process Overview

Use this dashboard to inspect monitored process groups:

- Resident memory (RSS, MiB)
- CPU usage over time
- Number of matching processes

Select a process group using the dashboard's process dropdown.

Groups depend on `config/process-exporter.yml` and the running processes on the Raspberry Pi.

For example, a custom configuration may expose:

- `job-watcher`
- `web-server`
- `chromium`
- `cloudflared`
- `prometheus`

Process names are not automatically equivalent to systemd unit names.

**Note:** Summed RSS can count shared memory pages more than once, especially for Chromium processes. Do not treat summed RSS as exact physical RAM consumption.

## Using Prometheus Directly

On the Raspberry Pi, Prometheus is available at:

http://127.0.0.1:9090

Useful PromQL queries:

| Metric | PromQL |
|--------|--------|
| CPU usage (%) | `100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))` |
| Available RAM (MiB) | `node_memory_MemAvailable_bytes / 1024 / 1024` |
| RAM usage (%) | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` |
| Root filesystem usage (%) | `100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})` |
| Process RSS (MiB) | `namedprocess_namegroup_memory_bytes{groupname="job-watcher",memtype="resident"} / 1024 / 1024` |
| Process count | `namedprocess_namegroup_num_procs{groupname="job-watcher"}` |
| Process CPU (%) | `100 * rate(namedprocess_namegroup_cpu_seconds_total{groupname="job-watcher"}[5m])` |

Adjust the `groupname` label to match the actual groups exposed by Process Exporter.

For direct Prometheus access from a computer, create a separate SSH tunnel:

```bash
ssh -N -L 9090:127.0.0.1:9090 lagee@lagee.local
```

Then visit http://localhost:9090.

## Configuration

| Repository file | Installed path |
|----------------|----------------|
| `config/prometheus.yml` | `/etc/prometheus/prometheus.yml` |
| `config/process-exporter.yml` | `/etc/prometheus/process-exporter.yml` |
| `grafana/grafana.env` | `/etc/pi-monitoring/grafana.env` |
| `grafana/systemd/override.conf` | `/etc/systemd/system/grafana-server.service.d/override.conf` |
| `grafana/provisioning/datasources/prometheus.yml` | `/etc/grafana/provisioning/datasources/prometheus.yml` |
| `grafana/provisioning/dashboards/pi-monitoring.yml` | `/etc/grafana/provisioning/dashboards/pi-monitoring.yml` |
| `grafana/dashboards/system-overview.json` | `/etc/grafana/dashboards/system-overview.json` |
| `grafana/dashboards/process-overview.json` | `/etc/grafana/dashboards/process-overview.json` |

Prometheus scrapes the configured targets every 30 seconds.

Retention settings:

```text
--storage.tsdb.retention.time=14d
--storage.tsdb.retention.size=2GB
```

Prometheus removes old blocks according to the applicable retention limits. The limits do not constitute a strict cap on total disk usage.

### Configuration ownership

The installer tracks configuration hashes in:

```text
/var/lib/pi-monitoring/config-state/
```

- Identical configurations are left unchanged.
- Managed configurations are updated when the repository changes.
- Manually modified managed configurations cause a conflict.
- Differing unmanaged configurations require `--adopt`.
- Replaced files are backed up before installation.

Configuration updates are not currently an atomic transaction, and automatic rollback is not implemented.

## Troubleshooting

Check service status:

```bash
systemctl status prometheus grafana-server
```

Inspect logs:

```bash
journalctl -u prometheus -n 50 --no-pager
journalctl -u prometheus-process-exporter -n 50 --no-pager
journalctl -u grafana-server -n 50 --no-pager
```

Check exporters:

```bash
curl -fsS http://127.0.0.1:9100/metrics | head
curl -fsS http://127.0.0.1:9256/metrics | head
```

Check process groups:

```bash
curl -fsS http://127.0.0.1:9256/metrics |
grep '^namedprocess_namegroup_num_procs'
```

If `lagee.local` cannot be resolved, replace it with the Raspberry Pi's LAN IP address.

## Development and CI

Validate locally:

```bash
bash -n install.sh
bash -n lib/config.sh

./tests/test-config.sh
./tests/test-service-args.sh

python3 -m json.tool grafana/dashboards/system-overview.json >/dev/null
python3 -m json.tool grafana/dashboards/process-overview.json >/dev/null

git diff --check
```

GitHub Actions executes syntax checks, unit tests, dashboard JSON validation, and whitespace checks.

## Limitations

- Only Debian 13 ARM64 is supported by the installer.
- Fresh installation from a clean OS is not yet fully tested.
- Configuration changes do not support automatic rollback.
- The installer manages monitoring components only; it does not install or restore custom applications such as Job Watcher or Web Server.
- Process monitoring shows resource usage and process counts, not application-level success or failure.
- Grafana is accessible through localhost or SSH tunneling, not directly exposed to the LAN.

## License

No license has been selected yet.
