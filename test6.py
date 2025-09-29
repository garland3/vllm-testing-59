import os
import requests
import base64
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Environment variables
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")
MODEL = os.getenv("MODEL", "openai/gpt-oss-20b")

def query_model_with_image(prompt):
    # Load and encode the image
    image_path = "test-img/test.png"
    with open(image_path, "rb") as image_file:
        image_data = base64.b64encode(image_file.read()).decode("utf-8")
    
    url = f"{BASE_URL}/v1/chat/completions"
    headers = {"Content-Type": "application/json"}
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/png;base64,{image_data}"}
                }
            ]
        }
    ]
    data = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": 300
    }

    response = requests.post(url, headers=headers, json=data)
    response.raise_for_status()
    result = response.json()
    content = result["choices"][0]["message"]["content"]
    return content

if __name__ == "__main__":
    try:
        print("Query 1: What is in this?")
        response1 = query_model_with_image("what is in this?")
        print(f"Response: {response1}\n")
        
        print("Query 2: How many cactus are there?")
        response2 = query_model_with_image("how many cactus are there?")
        print(f"Response: {response2}\n")
    except Exception as e:
        print(f"Error: {e}")
