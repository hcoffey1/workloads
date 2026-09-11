"""Capture zoning provenance outside the measured workload invocation."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def revision(path):
    def git(*args):
        return subprocess.check_output(
            ["git", "-C", str(path), *args], stderr=subprocess.DEVNULL
        )
    try:
        return {"commit": git("rev-parse", "HEAD").decode().strip(),
                "tracked_diff_sha256": hashlib.sha256(git("diff", "--binary", "HEAD")).hexdigest()}
    except subprocess.CalledProcessError:
        return None


def main():
    root, binary, wrapper = map(Path, sys.argv[1:4])
    dataset, output = sys.argv[4:6]
    if not dataset or Path(dataset).name != dataset or dataset in (".", ".."):
        raise ValueError("invalid dataset name")
    source = root / "MERCI/4_performance_evaluation"
    inputs = [root / "MERCI/data/4_filtered" / dataset / (dataset + "_test_filtered.txt")]
    files = [binary, wrapper, source / "Makefile", *inputs,
             *sorted((source / "src").glob("*.h")),
             *sorted((source / "src").glob("*.cc")),
             *sorted((root / "common/regent_regions").glob("*.h")),
             root / "scripts/workloads/merci.sh", Path(__file__),
             root / "scripts/workload_utils.sh", root / "run.sh"]
    libraries = []
    for name in ("HEMEMPOL", "SYS_ALLOC", "REGENT_EVOLVE_CANDIDATE"):
        for item in os.environ.get(name, "").split(":"):
            if item:
                path = Path(item).resolve()
                libraries.append({"setting": name, "path": str(path),
                                  "sha256": digest(path), "repository": revision(path.parent)})
    env = {k: v for k, v in os.environ.items()
           if k.startswith("MERCI_") or k.startswith("REGENT_") or k in
           ("NUMA_PLACEMENT", "OMP_NUM_THREADS", "USE_CGROUP", "CPUSET", "DRAMSIZE",
            "CXX", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LDLIBS")}
    result = {"schema_version": 1, "workload_repository": revision(root),
              "files_sha256": {str(p.resolve()): digest(p) for p in files},
              "configured_libraries": libraries, "environment": env,
              "note": "Requested settings; the wrapper and stdout manifest define effective zoning. Layout mode unsets LD_PRELOAD."}
    Path(output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
