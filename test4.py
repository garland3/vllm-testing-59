import requests
import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

API_URL = os.getenv("BASE_URL", "http://localhost:8000") + "/v1/chat/completions"  # Adjust for your vLLM endpoint
headers = {"Authorization": "Bearer sk-123456"}  # Use any dummy key unless your server authenticates

tools = [
    {
        "type": "function",
        "function": {
            "name": "get_current_weather",
            "description": "Get the current weather in a given location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {"type": "string", "description": "The city and state, e.g. San Francisco, CA"},
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
                },
                "required": ["location"]
            }
        }
    }
]

data = {
    "model": "openai/gpt-oss-20b",
    "messages": [
        {"role": "system", "content": "You are a helpful weather assistant. Use tool calling. "},
        {"role": "user", "content": "What's the weather like in Boston?"}
    ],
    "tools": tools,
    "tool_choice": "auto",
    "max_tokens": 256
}

response = requests.post(API_URL, headers=headers, json=data)
print(response.json())
