#!/usr/bin/env python3
import sys
import json
import base64
import urllib.request
import urllib.error

def main():
    if len(sys.argv) < 3:
        sys.stderr.write("Usage: compare_images.py <model> <prompt> <image1> <image2> ...\n")
        sys.exit(1)

    model = sys.argv[1]
    prompt = sys.argv[2]
    image_paths = sys.argv[3:]

    def get_b64(path):
        clean_p = path.strip().strip('"\'')
        with open(clean_p, "rb") as f:
            return base64.b64encode(f.read()).decode("utf-8")

    messages = []
    for idx, p in enumerate(image_paths, 1):
        clean_p = p.strip().strip('"\'')
        try:
            b64_data = get_b64(clean_p)
            messages.append({"role": "user", "content": f"Here is Image {idx}:", "images": [b64_data]})
            messages.append({"role": "assistant", "content": f"Received Image {idx}."})
        except Exception as e:
            sys.stderr.write(f"Failed to read image {p}: {e}\n")
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
            sys.stdout.write(content)
    except urllib.error.URLError as e:
        sys.stderr.write(f"Ollama API request failed: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
