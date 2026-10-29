#!/usr/bin/env python3
"""Build the domain-blocked qwen replay set from a WildChat-1M parquet shard.

Hand-picked first user turns, six per domain, written in block order (code, math/science,
creative, non-English) so each domain's hot expert set has a clean window in the heatmaps.
Writes {"id", "domain", "prompt"} JSONL; the replay client takes the first N lines.
Picks were drawn from keyword/language shortlists and read by hand; skipped were prompts
with no actual request, sexual content, or missing context. Needs pyarrow (dataVis env).

Usage: wildchat_domain_prompts.py <shard.parquet> <out.jsonl>
"""
import json
import sys

import pyarrow.parquet as pq

PICKS = [
    ("code", "e6d4bdf57570e7f5acdebe666656db96"),          # Python primality test
    ("code", "7f5a280af683645d5d308b2a61b36043"),          # JS D&D character generator
    ("code", "0cf22ed4f4c4b4d026f7e91a72c19ab5"),          # set a pixel in a Python image
    ("code", "e02a3243d2b57830d85a53ae158261bf"),          # Blender Python skeleton animation
    ("code", "893d3fd2cdce327edbe69c14880f8630"),          # Rust program fetching stock prices
    ("code", "4ced7d0dd9fe61430a1c052f74ae7f91"),          # JS card classes with play()
    ("math_science", "d9dbe9e0356aa594d9d20adb65f7ed3a"),  # derivative of ln((x+a)/(x+b))
    ("math_science", "a4597f0d8845e11b36208bbfb021a204"),  # Bayes: manager / bonus scheme
    ("math_science", "191c2f26a46a399730131a851bccbaa4"),  # AlCl3 boiling-point elevation
    ("math_science", "5f77ccd8feb79337d58462c2db57a5d5"),  # rectangle perimeter proof
    ("math_science", "b8ab2702543524752cfe3d7c5a9b9ffc"),  # integral of f'(x) on [0, 2]
    ("math_science", "e5f4f6cb86fd364c6a5820f488057648"),  # electrochemical cell electrode potential
    ("creative", "81c92d7c3ad941835b353ac1b1467d50"),      # choose-your-own-adventure time loop
    ("creative", "c536d50b2822c186d0a0cde1ea025f71"),      # poem: chocolate chip cookies
    ("creative", "5075c27a75c448736d88577e40b7ed5b"),      # story: humanity vs aliens, 2107
    ("creative", "3fae8a5cd08b2c6a310cf5a3a34976cd"),      # story: martial artist sent back in time
    ("creative", "42eec91b7670a428d6a535d95209411a"),      # poem: soldier in a space war
    ("creative", "02299aa0b565f43e574af0c0e03c910a"),      # story: man stranded on an island
    ("non_english", "67bed94a37e89b83111e94015d8680b9"),   # zh: Beijing May Day travel guide
    ("non_english", "0fce6f3b307f11877ddcd803ee3b7e8b"),   # zh: essay on homesickness, 500+ chars
    ("non_english", "4c77a5efb0c878d2384bbb93b26a2c2b"),   # ru: childhood in Tolstoy and Gorky
    ("non_english", "f84e6defc14c7838a9dfdb929414c902"),   # ru: foods for gaining weight fast
    ("non_english", "ab7fb8700944706fa141ba000f0f317f"),   # zh: criminal-law question on a forged diploma dispute
    ("non_english", "9e1c1ef41cf31f45d738e2f9644fdd34"),   # ru: who drowned Mumu in Turgenev's story
]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    want = {h for _, h in PICKS}
    rows = {r["conversation_hash"]: r for r in pq.read_table(
        src, columns=["conversation_hash", "conversation", "toxic", "redacted"]).to_pylist()
        if r["conversation_hash"] in want}
    missing = want - rows.keys()
    assert not missing, f"picks not in {src}: {sorted(missing)}"
    with open(dst, "w") as f:
        for domain, h in PICKS:
            r = rows[h]
            assert not r["toxic"] and not r["redacted"], f"{h} is flagged toxic/redacted"
            prompt = next(t["content"] for t in r["conversation"] if t["role"] == "user").strip()
            f.write(json.dumps({"id": h, "domain": domain, "prompt": prompt}, ensure_ascii=False) + "\n")
    print(f"{len(PICKS)} prompts -> {dst}")


if __name__ == "__main__":
    main()
