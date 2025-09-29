import os
import requests
from pydantic import BaseModel
from typing import List
import json
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Environment variables
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")
MODEL = os.getenv("MODEL", "openai/gpt-oss-20b")

class Variation(BaseModel):
    title: str
    description: str

class VariationsResponse(BaseModel):
    variations: List[Variation]

def get_variations():
    url = f"{BASE_URL}/v1/chat/completions"
    headers = {
        "Content-Type": "application/json"
    }
    schema = VariationsResponse.model_json_schema()
    data = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": "Generate 10 creative variation ideas for the nursery rhyme 'Twinkle Twinkle Little Star'. For each variation, provide a title and a brief description."
            }
        ],
        "guided_json": schema
    }

    response = requests.post(url, headers=headers, json=data)
    response.raise_for_status()
    result = response.json()

    # Parse the JSON response
    content = result["choices"][0]["message"]["content"]
    parsed = json.loads(content)

    response_obj = VariationsResponse(**parsed)
    return response_obj.variations

if __name__ == "__main__":
    try:
        variations = get_variations()
        for i, var in enumerate(variations, 1):
            print(f"{i}. {var.title}: {var.description}")
    except Exception as e:
        print(f"Error: {e}")