from pydantic import BaseModel


class Settings(BaseModel):
    service_name: str = "genai-health-demo"

    # App
    listen_host: str = "0.0.0.0"
    listen_port: int = 8080

    # Dependencies
    model_base_url: str = "http://127.0.0.1:9001"
    vector_base_url: str = "http://127.0.0.1:9002"

    # Budgets (ms)
    ready_model_budget_ms: int = 200
    ready_vector_budget_ms: int = 100

    deep_model_budget_ms: int = 400
    deep_vector_budget_ms: int = 200

    # Deep probe quality gates
    min_topk_count: int = 1
    min_topk_score: float = 0.55

    # OTel
    otlp_endpoint: str = "http://127.0.0.1:4317"  # OTLP gRPC mapped by docker


SETTINGS = Settings()
