#!/usr/bin/env python3
"""Build the llama_cpp replay prompt pool from a WildChat-1M parquet shard.

Keeps the first user turn of English, non-toxic, non-redacted conversations,
drops exact duplicates and very short/long prompts, shuffles with a fixed seed
and writes {"id", "prompt"} JSONL. The replay client takes the first N lines,
so the pool order is the benchmark's request order. Needs pyarrow (dataVis env).

Usage: wildchat_prompts.py <shard.parquet> <out.jsonl> [pool_size]
"""
import json
import random
import sys

import pyarrow.parquet as pq

MIN_CHARS, MAX_CHARS = 16, 6000  # ~4 chars/token: keeps prefill under ~1.5K tokens


def main():
    src, dst = sys.argv[1], sys.argv[2]
    pool_size = int(sys.argv[3]) if len(sys.argv) > 3 else 5000
    rows = pq.read_table(src, columns=["conversation_hash", "conversation", "language",
                                       "toxic", "redacted"]).to_pylist()
    seen, pool = set(), []
    for r in rows:
        if r["language"] != "English" or r["toxic"] or r["redacted"]:
            continue
        first = next((t["content"] for t in r["conversation"] if t["role"] == "user"), "")
        prompt = first.strip()
        if not MIN_CHARS <= len(prompt) <= MAX_CHARS or prompt in seen:
            continue
        seen.add(prompt)
        pool.append({"id": r["conversation_hash"], "prompt": prompt})

    random.Random(0).shuffle(pool)
    pool = pool[:pool_size]
    assert pool, f"no prompts survived filtering in {src}"
    with open(dst, "w") as f:
        for rec in pool:
            f.write(json.dumps(rec) + "\n")
    print(f"{len(pool)} prompts ({len(rows)} conversations scanned) -> {dst}")


if __name__ == "__main__":
    main()
