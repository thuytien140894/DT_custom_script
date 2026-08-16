#!/usr/bin/env python3
import sys
import json
import base64
import urllib.request
import urllib.error
import os

def log(msg):
    try:
        with open("/tmp/compare_debug.log", "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass

def get_b64(path):
    clean_p = path.strip().strip('"\'')
    with open(clean_p, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")

def main():
    log(f"[ENTRY] sys.argv={sys.argv}")

    if len(sys.argv) < 2:
        sys.stderr.write("Usage: compare_images.py <config.json> OR compare_images.py <model> <prompt> <img1> <img2>...\n")
        sys.exit(1)

    # Option 1: Config JSON file passed as sole argument
    if len(sys.argv) == 2 and sys.argv[1].endswith(".json") and os.path.exists(sys.argv[1]):
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            cfg = json.load(f)
        model = cfg.get("model", "")
        prompt = cfg.get("prompt", "")
        image_paths = cfg.get("images", [])
    # Option 2: CLI arguments
    elif len(sys.argv) >= 3:
        model = sys.argv[1]
        prompt = sys.argv[2]
        image_paths = sys.argv[3:]
    else:
        sys.stderr.write("Invalid arguments.\n")
        sys.exit(1)

    messages = []
    for idx, p in enumerate(image_paths, 1):
        clean_p = p.strip().strip('"\'')
        try:
            b64_data = get_b64(clean_p)
            messages.append({"role": "user", "content": f"Here is Image {idx}:", "images": [b64_data]})
            messages.append({"role": "assistant", "content": f"Received Image {idx}."})
        except Exception as e:
            log(f"[ERROR] Failed to read image {clean_p}: {e}")
            sys.stderr.write(f"Failed to read image {clean_p}: {e}\n")
            sys.exit(1)

    messages.append({"role": "user", "content": prompt})

    payload = json.dumps({"model": model, "messages": messages, "stream": False}).encode("utf-8")
    req = urllib.request.Request(
        "http://localhost:11434/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = data.get("message", {}).get("content", "")
            log(f"[SUCCESS] model={model} images={len(image_paths)}\nOutput:\n{content}")
            sys.stdout.write(content)
    except urllib.error.URLError as e:
        log(f"[ERROR] Ollama request failed: {e}")
        sys.stderr.write(f"Ollama API request failed: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
