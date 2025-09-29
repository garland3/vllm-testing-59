# Scripts for vllm setup. 

* I was trying to get the gpt-oss 20b model working but ran could not get tool calling to work with it. 
* Switched to Qwen3-8B and it worked right away, but not able to get podman working as a service yet.
* Playing with the Qwen2.5-VL-7B-Instruct vision model now.

huggingface-cli download Qwen/Qwen3-8B
# vllm serve Qwen/Qwen3-8B \
#   --enable-auto-tool-choice \
#   --tool-call-parser hermes


podman run -v /mnt/data/huggingface:/root/.cache/huggingface/hub \
  --rm --device nvidia.com/gpu=all \
  -p 8000:8000 --ipc=host \
  docker.io/vllm/vllm-openai:latest \
  --model Qwen/Qwen3-8B \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --gpu_memory_utilization 0.95


# 

# Replace "my-container" with your container name
# podman generate systemd --new --name busy_montalcini -f
# still having a hard time getting this to work qith quadlets


# or try the vision model. 

huggingface-cli download Qwen/Qwen2.5-VL-7B-Instruct


podman run -v /mnt/data/huggingface:/root/.cache/huggingface/hub \
  --rm --device nvidia.com/gpu=all \
  -p 8000:8000 --ipc=host \
  docker.io/vllm/vllm-openai:latest \
  --model Qwen/Qwen2.5-VL-7B-Instruct \
  --gpu_memory_utilization 0.95 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --max-model-len 50000