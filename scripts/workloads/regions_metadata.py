"""Capture zoning provenance outside the measured workload invocation.

Generic counterpart of merci_metadata.py for workloads whose source lives in a
submodule: the caller names the binary, generated wrapper, and the source
files/globs to fingerprint; the shared region helper, harness scripts, and
configured policy libraries are always included.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="workloads checkout")
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--wrapper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env-prefix", action="append", default=[],
                        help="record environment variables with this prefix (repeatable)")
    parser.add_argument("--file", action="append", default=[], type=Path,
                        help="file to fingerprint, relative to --root (repeatable)")
    parser.add_argument("--glob", action="append", default=[], nargs=2, metavar=("DIR", "PATTERN"),
                        help="fingerprint files matching PATTERN under DIR, relative to --root")
    parser.add_argument("--repository", action="append", default=[], type=Path,
                        help="extra repository (submodule) to record, relative to --root")
    args = parser.parse_args()
    root = args.root
    files = [args.binary, args.wrapper,
             *sorted((root / "common/regent_regions").glob("*.h")),
             root / "scripts/workload_utils.sh", root / "run.sh", Path(__file__)]
    files += [root / f for f in args.file]
    for directory, pattern in args.glob:
        files += sorted((root / directory).glob(pattern))
    libraries = []
    for name in ("HEMEMPOL", "SYS_ALLOC", "REGENT_EVOLVE_CANDIDATE"):
        for item in os.environ.get(name, "").split(":"):
            if item:
                path = Path(item).resolve()
                libraries.append({"setting": name, "path": str(path),
                                  "sha256": digest(path), "repository": revision(path.parent)})
    prefixes = tuple(args.env_prefix) + ("REGENT_",)
    env = {k: v for k, v in os.environ.items()
           if k.startswith(prefixes) or k in
           ("NUMA_PLACEMENT", "OMP_NUM_THREADS", "USE_CGROUP", "CPUSET", "DRAMSIZE",
            "CXX", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LDLIBS")}
    # The binary's own repository (a submodule) is recorded separately from the
    # workloads checkout so a dirty submodule is visible.
    repositories = {str(root): revision(root)}
    binary_repo = args.binary.resolve().parent
    repositories[str(binary_repo)] = revision(binary_repo)
    for extra in args.repository:
        repositories[str(root / extra)] = revision(root / extra)
    result = {"schema_version": 1, "repositories": repositories,
              "files_sha256": {str(p.resolve()): digest(p) for p in files},
              "configured_libraries": libraries, "environment": env,
              "note": "Requested settings; the wrapper and stdout manifest define effective zoning. Layout mode unsets LD_PRELOAD."}
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
