# Module 1: Production Reliability Fundamentals For GenAI Systems

This module contains demos that operationalize the theory from Module 1 clips.

## One-time module setup
If you already ran the course-level setup, you are done.

If you skipped course setup, run:
```bash
../../setup_all.sh
```

## Demos
- `demo-clip4-otel-health-probes/`
  - Implements `/live`, `/ready`, and a deep synthetic probe
  - Emits traces and metrics per dependency boundary
  - Injects a failure (Model 429) and proves degraded vs down

