"""Hardware-free executable, ABI, lifetime, and wrapper integration checks."""
import json
import hashlib
import os
import re
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
EVAL = ROOT / "MERCI/4_performance_evaluation"
BIN = EVAL / "bin/eval_baseline"
PAGE = 2 * 1024 * 1024


def rows(output, tag):
    return [json.loads(line[len(tag) + 1:]) for line in output.splitlines()
            if line.startswith(tag + " ")]


class RegionsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="merci-regions-test-")
        cls.home = Path(cls.temp.name)
        data = cls.home / "MERCI/data/4_filtered/tiny"
        data.mkdir(parents=True)
        # 7 expanded queries, split unevenly among 3 workers. Embedding storage
        # crosses a 2 MB boundary; output requires padding and prefaulting.
        (data / "tiny_test_filtered.txt").write_text(
            "# 9001\n2 1 3 7\n1 9000\n3 2 2 4\n1 8 0\n")
        cls.fake = cls.home / "fake.so"
        subprocess.run(["g++", "-std=c++11", "-shared", "-fPIC", str(EVAL / "tests/fake_regent.cpp"),
                        "-o", str(cls.fake)], check=True)
        cls.env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("REGENT_", "MERCI_", "FAKE_")) and k != "LD_PRELOAD"}
        cls.env.update(HOME=str(cls.home), OMP_NUM_THREADS="3")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_benchmark(self, args=(), env=None, success=True):
        settings = dict(self.env)
        settings.update(env or {})
        result = subprocess.run([str(BIN), "-d", "tiny", "-c", "3", "-r", "2", *args],
                                env=settings, capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("Average Time:", result.stdout)
            self.assertNotIn('"phase":"kernel_begin"', result.stdout)
        return result

    def application(self, **extra):
        return dict(LD_PRELOAD=str(self.fake), REGENT_REGION_MODE="application",
                    REGENT_FAST_MEMORY="6M", **extra)

    @staticmethod
    def declarations():
        return ["--app-regions", "--app-region", "output:evolve:2M",
                "--app-region", "embedding:simple_frequency:4M"]

    def test_application_outputs_order_lifetime_and_warmups(self):
        result = self.run_benchmark([*self.declarations(), "--verify", "--warmups", "1"],
                                    self.application())
        calls = rows(result.stdout, "FAKE_REGISTER")
        self.assertEqual([c["id"] for c in calls], [0, 1])
        self.assertEqual([c["size"] for c in calls], [2 * PAGE, PAGE])
        self.assertEqual([c["budget"] for c in calls], [2 * PAGE, PAGE])
        manifest, = rows(result.stdout, "REGENT_ZONE_MANIFEST")
        self.assertEqual(manifest["shuffle_seed"], 1)
        for zone, call in zip(manifest["zones"], calls):
            self.assertEqual(zone["base"], call["base"])
            self.assertEqual(zone["registered_bytes"], call["size"])
        self.assertEqual([z["logical_bytes"] for z in manifest["zones"]], [(9001 + 1) * 256, 7 * 256])  # rows 0..num_features (1-based ids)
        self.assertEqual(result.stdout.count("FAKE_RETAINED"), 2)
        events = rows(result.stdout, "MERCI_EVENT")
        ready = next(e["monotonic_ns"] for e in events if e["phase"] == "regions_ready")
        starts = [e for e in events if e["phase"] == "kernel_begin"]
        self.assertEqual([e["trial"] for e in starts], [-1, 0, 1])
        self.assertTrue(all(e["monotonic_ns"] >= ready for e in starts))
        checks = rows(result.stdout, "MERCI_VERIFY")
        f32 = lambda x: struct.unpack("f", struct.pack("f", x))[0]
        queries = [[1, 3, 7]] * 2 + [[9000]] + [[2, 2, 4]] * 3 + [[8, 0]]
        expected = 0
        for query in queries:
            value = 0
            for feature in query:
                value = f32(value + f32(0.01 * feature))
            expected += 64 * value
        self.assertEqual(len(checks), 3)
        for check in checks:
            self.assertEqual(check["rows"], 7)
            self.assertAlmostEqual(check["checksum"], expected, places=3)
        self.assertEqual(result.stdout.count("REPEAT #"), 2)
        self.assertEqual(result.stdout.count("WARMUP #"), 1)
        measured = [float(x) for x in re.findall(r"REPEAT # \d+ Baseline Total time : ([\d.e+-]+)", result.stdout)]
        mean = float(re.search(r"Average Time: ([\d.e+-]+)", result.stdout)[1])
        self.assertAlmostEqual(mean, sum(measured) / len(measured), places=10)

    def test_layout_and_legacy(self):
        legacy = self.run_benchmark(["--verify", "--shuffle-seed", "17"])
        layout = self.run_benchmark(["--region-layout-only", "--verify", "--shuffle-seed", "17"])
        self.assertNotIn("REGENT_ZONE_MANIFEST", legacy.stdout)
        self.assertEqual(rows(legacy.stdout, "MERCI_VERIFY"), rows(layout.stdout, "MERCI_VERIFY"))
        manifest, = rows(layout.stdout, "REGENT_ZONE_MANIFEST")
        self.assertTrue(all(z["registered_bytes"] == 0 for z in manifest["zones"]))
        self.assertEqual(manifest["shuffle_seed"], 17)

    def test_seed_reproducibility(self):
        manifests = []
        for seed in (17, 17, 29):
            result = self.run_benchmark(["--region-layout-only", "--shuffle-seed", str(seed)])
            manifests.append(rows(result.stdout, "REGENT_ZONE_MANIFEST")[0])
        self.assertEqual(manifests[0]["query_order_fnv1a64"], manifests[1]["query_order_fnv1a64"])
        self.assertNotEqual(manifests[0]["query_order_fnv1a64"], manifests[2]["query_order_fnv1a64"])

    def test_provenance(self):
        root = self.home / "metadata"
        (root / "MERCI").mkdir(parents=True)
        (root / "MERCI/4_performance_evaluation").symlink_to(EVAL)
        (root / "MERCI/data").symlink_to(self.home / "MERCI/data")
        for name in ("common", "scripts", "run.sh"):
            (root / name).symlink_to(ROOT / name)
        wrapper = self.home / "metadata-wrapper.sh"
        wrapper.write_text("#!/bin/sh\nexit 0\n")
        output = self.home / "metadata.json"
        subprocess.run(["python3", str(ROOT / "scripts/workloads/merci_metadata.py"), str(root),
                        str(BIN), str(wrapper), "tiny", str(output)], env=self.env, check=True)
        data = json.loads(output.read_text())
        self.assertEqual(data["schema_version"], 1)
        self.assertEqual(data["files_sha256"][str(wrapper)], hashlib.sha256(wrapper.read_bytes()).hexdigest())
        self.assertIn(str(BIN.resolve()), data["files_sha256"])
        self.assertIn(str(ROOT / "common/regent_regions/regions.h"), data["files_sha256"])

    def test_failures_prevent_measurement(self):
        for args, env in [
            (["--app-regions"], self.application()),
            (self.declarations(), {}),
            (self.declarations(), {"REGENT_REGION_MODE": "application", "REGENT_FAST_MEMORY": "6M"}),
            (self.declarations(), self.application(FAKE_FAIL_ID="0")),
            (self.declarations(), self.application(FAKE_FAIL_ID="1")),
            (self.declarations(), {**self.application(), "REGENT_FAST_MEMORY": "2M"}),
            (self.declarations(), self.application(REGENT_CLUSTER_CONFIG="stale.ini")),
            ([*self.declarations(), "--region-layout-only"], self.application()),
            (["--region-layout-only"], {"LD_PRELOAD": str(self.fake)}),
            ([*self.declarations(), "--app-region", "embedding:simple_frequency:0"], self.application()),
            (["--app-region", "embedding:simple_frequency:0"], {}),
            (["--shuffle-seed", "4294967296"], {}),
            (["--warmups", "-1"], {}),
            (["--unknown"], {}),
        ]:
            with self.subTest(args=args, env=env):
                self.run_benchmark(args, env, success=False)
        for bad in ["arms:2M", "memtis_freq:2M", "simple_frequency:1M", "simple_frequency:2MB",
                    "simple_frequency:-1", "simple_frequency:18446744073709551615T"]:
            with self.subTest(bad=bad):
                result = self.run_benchmark(["--app-regions", "--app-region", "embedding:" + bad,
                                             "--app-region", "output:simple_frequency:0"],
                                            self.application(), success=False)
                self.assertNotIn("FAKE_REGISTER", result.stdout)

    def test_zero_budgets(self):
        self.run_benchmark(["--app-regions", "--app-region", "embedding:simple_frequency:0",
                            "--app-region", "output:simple_frequency:0"], self.application())

    def test_buffer_contract_cxx11(self):
        binary = self.home / "buffer_test"
        subprocess.run(["g++", "-std=c++11", "-O2", "-Wall", "-Wextra", "-pthread",
                        "-I" + str(ROOT / "common"), str(EVAL / "tests/buffer_test.cpp"),
                        "-ldl", "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

    def test_wrapper_quoting_and_mode(self):
        # Execute the generated POSIX shell, using a stub program instead of
        # NUMA/perf machinery. Include shell metacharacters as literal data.
        script = r'''
source "$CUR_PATH/scripts/workloads/merci.sh"
config_merci
merci_prepare_args || exit
SYS_ALLOC= HEMEMPOL= DRAMSIZE= MIN_INTERPOSE_MEM_SIZE= REGENT_TARGET_EXE=
PIDFILE="$TEST_HOME/wrapper.pid"
create_workload_wrapper "$TEST_HOME/wrapper.sh" "$PIDFILE" "$TEST_HOME/args.py" "$MERCI_ARGS" "$MERCI_EXTRA_ENV"
/bin/sh "$TEST_HOME/wrapper.sh"
'''
        stub = self.home / "args.py"
        stub.write_text("#!/usr/bin/python3\nimport json,os,sys\nprint('ARGS '+json.dumps(sys.argv[1:]))\n"
                        "print('MODE '+str(os.getenv('REGENT_REGION_MODE')))\n"
                        "assert 'REGENT_CLUSTER_CONFIG' not in os.environ\n")
        stub.chmod(0o755)
        literal = "a ' quote; $(touch SHOULD_NOT_EXIST)"
        env = dict(self.env, CUR_PATH=str(ROOT), TEST_HOME=str(self.home), MERCI_REGION_MODE="application",
                   MERCI_EMBEDDING_POLICY="simple_frequency", MERCI_EMBEDDING_FAST="4M",
                   MERCI_OUTPUT_POLICY="evolve", MERCI_OUTPUT_FAST="2M", MERCI_DATASET=literal,
                   REGENT_CLUSTER_CONFIG="stale", MERCI_SHUFFLE_SEED="3")
        result = subprocess.run(["bash", "-c", script], env=env, cwd=self.home,
                                capture_output=True, text=True, check=True)
        self.assertIn("MODE application", result.stdout)
        args, = rows(result.stdout, "ARGS")
        self.assertEqual(args[1], literal)
        self.assertFalse((self.home / "SHOULD_NOT_EXIST").exists())
        for key in list(env):
            if key.startswith(("MERCI_EMBEDDING_", "MERCI_OUTPUT_")) or key == "REGENT_CLUSTER_CONFIG":
                env.pop(key)
        env["MERCI_REGION_MODE"] = "layout"
        result = subprocess.run(["bash", "-c", script], env=env, cwd=self.home,
                                capture_output=True, text=True, check=True)
        self.assertIn("MODE None", result.stdout)
        env["MERCI_REGION_MODE"] = "wrong"
        self.assertNotEqual(subprocess.run(["bash", "-c", script], env=env, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
