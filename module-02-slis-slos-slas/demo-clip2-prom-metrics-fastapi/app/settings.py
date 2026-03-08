from pydantic import BaseModel

class Settings(BaseModel):
    service_name: str = "genai-sli-demo"
    retrieval_base_url: str = "http://localhost:9002"
    model_base_url: str = "http://localhost:9001"
    tools_base_url: str = "http://localhost:9003"

    # budgets (ms)
    budget_retrieval_ms: int = 100
    budget_model_ms: int = 200
    budget_tools_ms: int = 150

    # cost model (dollars)
    cost_per_1k_input_tokens: float = 0.003
    cost_per_1k_output_tokens: float = 0.006

SETTINGS = Settings()
