#!/usr/bin/env python3
"""Single-user prompt replay against llama-server (stdlib only).

Sends prompts from a JSONL file ({"id", "prompt"} per line) one at a time to
/v1/chat/completions and records the server's own timings per request. Exits
non-zero if any request fails so run.sh reports the run as failed.
"""
import argparse
import json
import sys
import time
import urllib.request


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--prompts", required=True)
    p.add_argument("--n", type=int, default=100, help="replay the first N prompts")
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--out", required=True, help="per-request JSONL results")
    a = p.parse_args()

    with open(a.prompts) as f:
        prompts = [json.loads(line) for _, line in zip(range(a.n), f)]
    if len(prompts) < a.n:
        print(f"WARNING: only {len(prompts)} prompts available (asked for {a.n})", file=sys.stderr)

    url = f"http://{a.host}:{a.port}/v1/chat/completions"
    failed = 0
    t_run = time.time()
    with open(a.out, "w") as out:
        for i, rec in enumerate(prompts):
            body = json.dumps({
                "messages": [{"role": "user", "content": rec["prompt"]}],
                "max_tokens": a.max_tokens,
                "temperature": 0,
                "seed": a.seed,
            }).encode()
            req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
            t0 = time.time()
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:
                    resp = json.load(r)
            except Exception as e:  # keep replaying; the failure is counted and reported
                failed += 1
                print(f"[{i}] {rec['id']} FAILED: {e}", file=sys.stderr)
                continue
            msg = resp["choices"][0].get("message", {})
            row = {"idx": i, "id": rec["id"], "wall_s": round(time.time() - t0, 3),
                   "finish_reason": resp["choices"][0].get("finish_reason"),
                   "reasoning_chars": len(msg.get("reasoning_content") or ""),
                   "content_chars": len(msg.get("content") or ""), **resp.get("timings", {})}
            out.write(json.dumps(row) + "\n")
            out.flush()
            print(f"[{i}] prompt_n={row.get('prompt_n')} predicted_n={row.get('predicted_n')} "
                  f"pp={row.get('prompt_per_second', 0):.1f} tg={row.get('predicted_per_second', 0):.2f} tok/s")

    print(f"done: {len(prompts) - failed}/{len(prompts)} ok in {time.time() - t_run:.1f}s -> {a.out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
