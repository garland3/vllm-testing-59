import os
import requests
from datetime import datetime
import json
import inspect
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# ANSI color codes
RED = '\033[91m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
CYAN = '\033[96m'
MAGENTA = '\033[95m'
ENDC = '\033[0m'

# Environment variables
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")
MODEL = os.getenv("MODEL", "openai/gpt-oss-20b")
print(f"{CYAN}Using BASE_URL: {BASE_URL}, MODEL: {MODEL}{ENDC}")

def get_clock_time():
    """Get the current clock time."""
    result = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{GREEN}get_clock_time called, returning: {result}{ENDC}")
    return result

def eval_expression(expression: str):
    """Evaluate a Python expression safely."""
    print(f"{YELLOW}eval_expression called with: {expression}{ENDC}")
    try:
        # Note: eval is dangerous, use with caution
        result = eval(expression)
        print(f"{GREEN}eval_expression result: {result}{ENDC}")
        return str(result)
    except Exception as e:
        error_msg = f"Error: {str(e)}"
        print(f"{RED}eval_expression error: {error_msg}{ENDC}")
        return error_msg

def get_function_schema(func):
    """Use reflection to generate JSON schema for function parameters."""
    print(f"{BLUE}Generating schema for function: {func.__name__}{ENDC}")
    sig = inspect.signature(func)
    properties = {}
    required = []
    for param in sig.parameters.values():
        if param.name == 'self':
            continue
        # Simplistic type inference
        param_type = "string"  # default
        if param.annotation != inspect.Parameter.empty:
            if param.annotation == int:
                param_type = "integer"
            elif param.annotation == float:
                param_type = "number"
            elif param.annotation == bool:
                param_type = "boolean"
            # else string
        properties[param.name] = {
            "type": param_type,
            "description": f"Parameter {param.name}"
        }
        if param.default == inspect.Parameter.empty:
            required.append(param.name)
    schema = {
        "type": "object",
        "properties": properties,
        "required": required
    }
    print(f"{BLUE}Schema for {func.__name__}: {json.dumps(schema, indent=2)}{ENDC}")
    return schema

# Define tools using reflection
functions = {
    "get_clock_time": get_clock_time,
    "eval_expression": eval_expression
}

tools = []
for name, func in functions.items():
    schema = get_function_schema(func)
    tool = {
        "type": "function",
        "function": {
            "name": name,
            "description": func.__doc__ or f"Call {name}",
            "parameters": schema
        }
    }
    tools.append(tool)
    print(f"{MAGENTA}Added tool: {name}{ENDC}")

print(f"{CYAN}Total tools defined: {len(tools)}{ENDC}")

def call_function(name, args):
    print(f"{YELLOW}Calling function: {name} with args: {args}{ENDC}")
    if name in functions:
        result = functions[name](**args)
        print(f"{GREEN}Function {name} returned: {result}{ENDC}")
        return result
    else:
        error = f"Unknown function: {name}"
        print(f"{RED}{error}{ENDC}")
        return error

def chat_with_tools():
    # Initial conversation messages include a system prompt that strongly nudges the model
    # to actually invoke the provided tools instead of answering directly.
    user_question = "What time is it? Also, evaluate 2 + 2."
    messages = [
        {
            "role": "system",
            "content": (
                "You are a tool-using assistant. Whenever the user asks for the current time, "
                "YOU MUST call the get_clock_time tool. For any arithmetic or Python expression, "
                "YOU MUST call eval_expression with the expression. Do NOT refuse saying you don't \n"
                "have access to time; instead, call get_clock_time. After obtaining required tool results, "
                "compose a concise helpful answer."
            )
        },
        {"role": "user", "content": user_question}
    ]
    print(f"{CYAN}Starting chat with initial messages:{ENDC}")
    for msg in messages:
        print(f"  {msg}")

    iteration = 0
    fallback_injected = False
    attempted_legacy = False
    while True:
        iteration += 1
        print(f"\n{MAGENTA}--- Iteration {iteration} ---{ENDC}")
        print(f"{BLUE}Sending request to LLM...{ENDC}")
        payload = {
            "model": MODEL,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto"
        }

        try:
            response = requests.post(
                f"{BASE_URL}/v1/chat/completions",
                json=payload,
                timeout=120
            )
            if response.status_code >= 400:
                print(f"{RED}Server returned status {response.status_code}{ENDC}")
                print(f"{RED}Response body: {response.text[:2000]}{ENDC}")
                # Fallback: try legacy 'functions' API if not yet attempted
                if not attempted_legacy:
                    attempted_legacy = True
                    legacy_functions = [
                        {
                            "name": t["function"]["name"],
                            "description": t["function"].get("description", ""),
                            "parameters": t["function"].get("parameters", {"type": "object", "properties": {}})
                        } for t in tools
                    ]
                    legacy_payload = {
                        "model": MODEL,
                        "messages": messages,
                        "functions": legacy_functions,
                        "function_call": "auto"
                    }
                    print(f"{YELLOW}Retrying with legacy functions API...{ENDC}")
                    legacy_resp = requests.post(
                        f"{BASE_URL}/v1/chat/completions",
                        json=legacy_payload,
                        timeout=120
                    )
                    if legacy_resp.status_code < 400:
                        response = legacy_resp
                        print(f"{GREEN}Legacy functions API succeeded.{ENDC}")
                    else:
                        print(f"{RED}Legacy functions API also failed ({legacy_resp.status_code}). Falling back to manual execution.{ENDC}")
                        # Manual fallback: inject tool outputs and ask model again WITHOUT tools
                        if not fallback_injected:
                            manual_time = get_clock_time()
                            manual_math = eval_expression("2 + 2")
                            messages.append({"role": "tool", "tool_call_id": "manual_time", "content": manual_time})
                            messages.append({"role": "tool", "tool_call_id": "manual_math", "content": manual_math})
                            messages.append({"role": "user", "content": "Answer the question using the provided tool results above."})
                            fallback_injected = True
                            continue
                        else:
                            print(f"{RED}Aborting after repeated failures.{ENDC}")
                            break
                else:
                    # Already attempted legacy; perform manual fallback if not done
                    if not fallback_injected:
                        print(f"{YELLOW}Performing manual fallback after legacy attempt.{ENDC}")
                        manual_time = get_clock_time()
                        manual_math = eval_expression("2 + 2")
                        messages.append({"role": "tool", "tool_call_id": "manual_time", "content": manual_time})
                        messages.append({"role": "tool", "tool_call_id": "manual_math", "content": manual_math})
                        messages.append({"role": "user", "content": "Answer the question using the provided tool results above."})
                        fallback_injected = True
                        continue
                    else:
                        print(f"{RED}Aborting after repeated failures.{ENDC}")
                        break
            result = response.json()
        except requests.exceptions.RequestException as e:
            print(f"{RED}Request exception: {e}{ENDC}")
            if not fallback_injected:
                print(f"{YELLOW}Attempting one manual fallback iteration due to exception.{ENDC}")
                manual_time = get_clock_time()
                manual_math = eval_expression("2 + 2")
                messages.append({"role": "tool", "tool_call_id": "manual_time", "content": manual_time})
                messages.append({"role": "tool", "tool_call_id": "manual_math", "content": manual_math})
                messages.append({"role": "user", "content": "Answer the question using the provided tool results above."})
                fallback_injected = True
                continue
            else:
                break
        message = result["choices"][0]["message"]
        print(f"{GREEN}Received message from LLM: {message}{ENDC}")
        messages.append(message)

        if "tool_calls" in message:
            print(f"{YELLOW}Tool calls detected:{ENDC}")
            for tool_call in message["tool_calls"]:
                function_name = tool_call["function"]["name"]
                function_args = json.loads(tool_call["function"]["arguments"])
                print(f"  {CYAN}Calling {function_name} with {function_args}{ENDC}")
                function_result = call_function(function_name, function_args)
                tool_message = {
                    "role": "tool",
                    "tool_call_id": tool_call["id"],
                    "content": function_result
                }
                messages.append(tool_message)
                print(f"  {GREEN}Appended tool result: {tool_message}{ENDC}")
            # After providing tool outputs, ask model to integrate them.
            print(f"{BLUE}Requesting model to integrate tool results...{ENDC}")
            messages.append({
                "role": "user",
                "content": "Please use the tool results you just received to answer the original question succinctly."
            })
            continue  # next iteration to get final answer
        else:
            # Heuristic fallback: if the model did NOT call tools but we expected them, we inject tool outputs manually once.
            expecting_time = "time" in user_question.lower()
            expecting_math = any(token in user_question for token in ["+", "-", "*", "/"]) or "evaluate" in user_question.lower()
            if not fallback_injected and (expecting_time or expecting_math):
                print(f"{YELLOW}No tool_calls returned; activating fallback heuristic.{ENDC}")
                if expecting_time:
                    manual_time = get_clock_time()
                    messages.append({
                        "role": "tool",
                        "tool_call_id": "fallback_get_clock_time",
                        "content": manual_time
                    })
                    print(f"{GREEN}Injected fallback get_clock_time result: {manual_time}{ENDC}")
                if expecting_math:
                    expr = "2 + 2"  # from the known user_question; could be parsed more generally
                    manual_math = eval_expression(expr)
                    messages.append({
                        "role": "tool",
                        "tool_call_id": "fallback_eval_expression",
                        "content": manual_math
                    })
                    print(f"{GREEN}Injected fallback eval_expression result: {manual_math}{ENDC}")
                messages.append({
                    "role": "user",
                    "content": "You have the tool results above. Please answer the original question now."
                })
                fallback_injected = True
                continue  # loop again to let model craft final answer

            print(f"{RED}No tool calls (or finished). Final response:{ENDC}")
            print(f"{GREEN}{message['content']}{ENDC}")
            break

if __name__ == "__main__":
    chat_with_tools()