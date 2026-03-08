from prometheus_client import Histogram, Counter, Gauge

# End-to-end latency (seconds)
genai_request_latency_seconds = Histogram(
    "genai_request_latency_seconds",
    "End-to-end request latency (seconds)",
    buckets=(0.01, 0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.75, 1.0, 2.0, 5.0),
)

# Dependency latency (seconds), labeled per dependency boundary
genai_dependency_latency_seconds = Histogram(
    "genai_dependency_latency_seconds",
    "Dependency latency (seconds)",
    labelnames=("dependency",),
    buckets=(0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 1.0, 2.0),
)

# Dependency errors, labeled by dependency boundary and error type
genai_dependency_errors_total = Counter(
    "genai_dependency_errors_total",
    "Dependency errors",
    labelnames=("dependency", "error_type"),
)

# Tokens and cost
genai_tokens_in_total = Counter("genai_tokens_in_total", "Total input tokens")
genai_tokens_out_total = Counter("genai_tokens_out_total", "Total output tokens")

genai_cost_per_request_dollars = Histogram(
    "genai_cost_per_request_dollars",
    "Cost per request (dollars)",
    buckets=(0.0, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05),
)

genai_cost_per_success_dollars = Histogram(
    "genai_cost_per_success_dollars",
    "Cost per successful request (dollars)",
    buckets=(0.0, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05),
)

# Quality proxy score (0..1)
genai_quality_proxy_score = Gauge(
    "genai_quality_proxy_score",
    "Online quality proxy score (0..1)",
)
