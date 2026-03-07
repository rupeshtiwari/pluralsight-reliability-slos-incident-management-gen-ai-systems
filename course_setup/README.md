# Reliability, SLOs, and Incident Management for GenAI Systems

This repo contains the **course demos** for **Reliability, SLOs And Incident Management For GenAI Systems**.

## What you get
- One-click environment setup for macOS
- Module folders with demo folders
- Each demo has:
  - a README with run steps and expected outputs
  - source code
  - scripts to start, stop, and inject failures

## Quick start (macOS)

### 0) Requirements
- macOS (Intel or Apple Silicon)
- Admin password (for installs)
- Stable internet

### 1) Clone
```bash
git clone <YOUR_GITHUB_URL>
cd outline-reliability-slos-incident-management-gen-ai-systems-repo
```

### 2) One-time setup (installs tools)
```bash
./setup_all.sh
```

This installs:
- Homebrew (if missing)
- Git, curl, jq
- Python 3.11
- Docker Desktop (cask)

### 3) Run Module 1, Clip 4 demo
```bash
cd module-01-production-reliability-fundamentals/demo-clip4-otel-health-probes
./scripts/demo_up.sh
./scripts/demo_run_story.sh
```

### 4) Stop everything
```bash
./scripts/demo_down.sh
```

## Folder structure
- `module-01-production-reliability-fundamentals/`
  - `demo-clip4-otel-health-probes/`

## Ports used
- App: `8080`
- Model stub: `9001`
- Vector stub: `9002`
- Grafana: `3000`
- Tempo: `3200`
- Prometheus: `9090`
- OpenTelemetry Collector (OTLP gRPC): `4317`

## Safety notes
- Demos are local-only. No cloud resources are created.
- Failure injection is reversible via `/admin/mode` endpoints.

