#!/usr/bin/env bash
# test_vllm_api.sh
# Quick smoke tests against a vLLM OpenAI-compatible server.
# Hits: /v1/models, /v1/chat/completions, /v1/completions, /v1/embeddings
# Optional: /health if enabled in future (ignored if 404)
#
# Usage:
#   ./test_vllm_api.sh                 # defaults to http://localhost:8000
#   BASE_URL=http://server:8000 MODEL=openai/gpt-oss-20b ./test_vllm_api.sh
#   OPENAI_API_KEY=sk-xyz ./test_vllm_api.sh   # if the server enforces an API key
#
# Requirements: curl; jq (optional for pretty output)

set -euo pipefail

BASE_URL=${BASE_URL:-"http://localhost:8000"}
MODEL=${MODEL:-"openai/gpt-oss-20b"}
API_KEY=${OPENAI_API_KEY:-""}
TIMEOUT=${TIMEOUT:-5}
RETRIES=${RETRIES:-20}   # wait up to ~RETRIES*TIMEOUT seconds for startup
SILENT=${SILENT:-0}

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

color_enabled=0
if [[ -t 1 ]]; then color_enabled=1; fi
if (( color_enabled )); then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_CYAN='\033[0;36m'; C_OFF='\033[0m'
else
  C_GREEN=''; C_RED=''; C_YEL=''; C_CYAN=''; C_OFF=''
fi

info(){ (( SILENT )) || echo -e "${C_CYAN}[INFO]${C_OFF} $*"; }
ok(){ (( SILENT )) || echo -e "${C_GREEN}[ OK ]${C_OFF} $*"; }
warn(){ echo -e "${C_YEL}[WARN]${C_OFF} $*" >&2; }
fail(){ echo -e "${C_RED}[FAIL]${C_OFF} $*" >&2; exit 1; }

_auth_headers(){
  if [[ -n $API_KEY ]]; then printf 'Authorization: Bearer %s' "$API_KEY"; fi
}

_curl(){
  local method=$1; shift
  local path=$1; shift
  local data=${1:-}
  local url="${BASE_URL}${path}"
  local hdrs=("-H" "Content-Type: application/json")
  if [[ -n $API_KEY ]]; then hdrs+=("-H" "Authorization: Bearer ${API_KEY}"); fi
  local args=(-sS -X "$method" "${hdrs[@]}" --max-time 120)
  [[ -n $data ]] && args+=(--data "$data")
  local http_code body
  # Use printf to avoid word splitting issues
  body=$(curl "${args[@]}" -w '\n%{http_code}' "$url" || true)
  http_code=${body##*$'\n'}
  body=${body%$'\n'*}
  [[ $have_jq -eq 1 ]] && body_pretty=$(printf '%s' "$body" | jq -r '.') || body_pretty=$body
  echo "$http_code" "$body_pretty"
}

wait_until_ready(){
  info "Waiting for API to become ready at ${BASE_URL} ..."
  local i=0
  while (( i < RETRIES )); do
    local code body
    read -r code body < <(_curl GET "/v1/models")
    if [[ $code == 200 ]]; then
      ok "API responded (models)."
      return 0
    fi
    (( i++ ))
    sleep "$TIMEOUT"
  done
  fail "API did not become ready after $((RETRIES*TIMEOUT)) seconds"
}

print_section(){ (( SILENT )) && return; echo -e "\n${C_CYAN}=== $* ===${C_OFF}"; }

run_models(){
  print_section "GET /v1/models"
  read -r code body < <(_curl GET "/v1/models")
  [[ $code == 200 ]] || fail "/v1/models returned $code"
  echo "$body" | ( [[ $have_jq -eq 1 ]] && jq '. | {object, data_count:(.data|length)}' || cat )
  ok "Models listed."
}

run_chat(){
  print_section "POST /v1/chat/completions"
  local payload
  payload=$(cat <<JSON
{
  "model": "${MODEL}",
  "messages": [
    {"role": "system", "content": "You are a test assistant."},
    {"role": "user", "content": "Say a single word: ping"}
  ],
  "max_tokens": 16,
  "temperature": 0.0
}
JSON
)
  read -r code body < <(_curl POST "/v1/chat/completions" "$payload")
  [[ $code == 200 ]] || fail "chat/completions returned $code"
  echo "$body" | ( [[ $have_jq -eq 1 ]] && jq '{id, model, choices: [.choices[0].message.content]}' || cat )
  ok "Chat completion succeeded."
}

run_completion(){
  print_section "POST /v1/completions"
  local payload
  payload=$(cat <<JSON
{
  "model": "${MODEL}",
  "prompt": "Complete the sequence: 1, 1, 2, 3, 5,",
  "max_tokens": 8,
  "temperature": 0.0
}
JSON
)
  read -r code body < <(_curl POST "/v1/completions" "$payload")
  [[ $code == 200 ]] || fail "completions returned $code"
  echo "$body" | ( [[ $have_jq -eq 1 ]] && jq '{id, model, text: .choices[0].text}' || cat )
  ok "Completion endpoint succeeded."
}

run_embeddings(){
  print_section "POST /v1/embeddings"
  local payload
  payload=$(cat <<JSON
{
  "model": "${MODEL}",
  "input": ["hello world", "second line"]
}
JSON
)
  read -r code body < <(_curl POST "/v1/embeddings" "$payload")
  [[ $code == 200 ]] || fail "embeddings returned $code"
  # Only show dimensions, not full vectors
  echo "$body" | ( [[ $have_jq -eq 1 ]] && jq '{count: (.data|length), dims: (.data[0].embedding|length)}' || cat )
  ok "Embeddings endpoint succeeded."
}

run_optional_health(){
  local code body
  read -r code body < <(_curl GET "/health") || true
  if [[ $code == 200 ]]; then
    print_section "GET /health"
    echo "$body"
    ok "Health endpoint OK."
  fi
}

main(){
  wait_until_ready
  run_models
  run_chat
  run_completion
  run_embeddings
  run_optional_health
  ok "All tests finished successfully."
}

main "$@"
