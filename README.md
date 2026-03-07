# Reliability, SLOs, and Incident Management for GenAI Systems

This repository contains the hands-on demos for the Pluralsight course:

**Reliability, SLOs, and Incident Management for GenAI Systems**

## What you will learn

By running these demos, you will learn how to operate GenAI systems with an SRE mindset:

* Define service health beyond HTTP 200
* Use liveness and readiness checks correctly
* Detect soft failures such as quality collapse, retrieval drift, and throttling
* Validate failures with traces and metrics
* Use synthetic probes to verify end-to-end behavior

## Repository structure

```text
.
├── README.md
├── course_setup/
│   ├── README.md
│   └── setup_all.sh
├── module-01-production-reliability-fundamentals/
│   ├── README.md
│   ├── setup_module.sh
│   └── demo-clip4-otel-health-probes/
│       ├── README.md
│       ├── app/
│       ├── infra/
│       └── scripts/
└── demos/
    └── README.md
```

## Where to start

1. Run the course-level setup to install prerequisites
2. Open the module you want to work on
3. Run the demo scripts inside that demo folder

## Requirements

These instructions assume:

* You are using macOS
* You are starting on a machine with no required tools installed

The course setup installs:

* Homebrew
* Python 3
* Docker Desktop
* Git
* curl
* jq

After installation, open Docker Desktop once and wait until it shows that Docker is running.

## One-time setup

From the repository root:

```bash
./course_setup/setup_all.sh
```

Then start Docker Desktop if needed:

```bash
open -a Docker
```

Wait until Docker is running, then verify:

```bash
docker version
docker compose version
```

## Run your first demo

This example uses Module 1, Clip 4.

### Start the demo

```bash
cd module-01-production-reliability-fundamentals/demo-clip4-otel-health-probes
./scripts/demo_up.sh
```

### Open the UI

```bash
./scripts/open_ui.sh
```

Expected:

* Grafana: [http://localhost:3000](http://localhost:3000)

### Run the scenario

```bash
./scripts/run_story.sh
```

This demo includes:

* `/live` for liveness
* `/ready` for readiness and dependency gating
* `/probe/deep` for deeper synthetic validation
* OpenTelemetry traces and Prometheus metrics
* Grafana and Tempo for observability

Expected behavior:

* `/live` remains healthy even if a downstream dependency fails
* `/ready` returns `ok` or `degraded` and identifies the failing boundary
* `/probe/deep` fails with a clear boundary and reason
* Grafana shows probe success and failure
* Tempo traces show the failing dependency span

### Shut down

```bash
./scripts/demo_down.sh
```

## Troubleshooting

### Docker commands fail

Make sure Docker Desktop is running:

```bash
open -a Docker
docker version
```

### App does not become ready

Check the application log:

```bash
tail -n 80 .run/app.log
```

### Port already in use

Common ports used by the demo:

* 8080 for the app
* 3000 for Grafana
* 9090 for Prometheus
* 3200 for Tempo

Check what is using a port:

```bash
lsof -nP -iTCP:3000 | grep LISTEN
```

## Safety notes

These demos run locally using Docker and local Python processes.

No AWS resources are created by default.

## Next steps

Each module folder contains:

* `README.md` for module overview and prerequisites
* `setup_module.sh` for module-specific setup
* Demo folders with their own `README.md` and scripts

Start
