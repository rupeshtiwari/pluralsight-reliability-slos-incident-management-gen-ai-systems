from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    model_config = {"protected_namespaces": ("settings_",)}

    service_name: str = "genai-slo-demo"
    model_base_url: str = "http://localhost:9001"
    retrieval_base_url: str = "http://localhost:9002"
    tools_base_url: str = "http://localhost:9003"
    budget_model_ms: int = 250
    budget_retrieval_ms: int = 120
    budget_tools_ms: int = 200
    cost_per_1k_input_tokens: float = 0.003
    cost_per_1k_output_tokens: float = 0.006

SETTINGS = Settings()
