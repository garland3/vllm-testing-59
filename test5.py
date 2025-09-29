import os
from openai import OpenAI
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

model = os.getenv("MODEL", "openai/gpt-oss-20b")

client = OpenAI(
    # base_url="https://router.huggingface.co/v1",
    # api_key=os.getenv("HF_TOKEN"),
    base_url=os.getenv("BASE_URL", "http://localhost:8000") + "/v1",
    api_key="sk-123456"  # Use any dummy key unless your server authenticates
)

tools = [
    {
        "type": "function",
        "function": {
            "name": "get_current_weather",
            "description": "Get the current weather in a given location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "The city and state, e.g. San Francisco, CA",
                    },
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
                },
                "required": ["location"],
            },
        },
    }
]

response = client.chat.completions.create(
    model=model,
    messages=[{"role": "user", "content": "What is the weather in Paris in Celsius? use the tools"}],
    tools=tools,
    tool_choice="auto",
)

# The response will contain the tool_calls object if the model decides to use the tool
print(response.choices[0].message)