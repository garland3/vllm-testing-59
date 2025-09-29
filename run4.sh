# podman run -v  /external/sd1/my-cache-2/hub:/root/.cache/huggingface/hub  --rm --device nvidia.com/gpu=all -p 8000:8000 --ipc=host -e VLLM_DISABLE_SINKS=1 -e VLLM_ATTENTION_BACKEND=TRITON_ATTN_VLLM_V1 vllm/vllm-openai:gptoss --model openai/gpt-oss-20b --quantization mxfp4 


uv .venv venv
source .venv/bin/activate
uv pip install huggingface_hub --upgrade
# echo $HF_HOME
echo $HF_HOME
/external/sd1/hf-cache
 huggingface-cli download openai/gpt-oss-20

# this was working for me. 
podman run -v  /mnt/data/huggingface:/root/.cache/huggingface/hub  --rm --device nvidia.com/gpu=all -p 8000:8000 --ipc=host -e VLLM_DISABLE_SINKS=1 -e VLLM_ATTENTION_BACKEND=TRITON_ATTN_VLLM_V1 vllm/vllm-openai:gptoss --model openai/gpt-oss-20b --quantization mxfp4 

# with tool calling?
# daemon mode, add a -d
podman run -v  /mnt/data/huggingface:/root/.cache/huggingface/hub  --rm --device nvidia.com/gpu=all -p 8000:8000 --ipc=host -e VLLM_DISABLE_SINKS=1 -e VLLM_ATTENTION_BACKEND=TRITON_ATTN_VLLM_V1 vllm/vllm-openai:gptoss --model openai/gpt-oss-20b --quantization mxfp4   --enable-auto-tool-choice  --tool-call-parser llama3_json --reasoning-parser openai