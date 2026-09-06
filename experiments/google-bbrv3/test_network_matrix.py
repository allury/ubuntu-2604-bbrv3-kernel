import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

SCRIPT = pathlib.Path(__file__).with_name("network_matrix.py")
SPEC = importlib.util.spec_from_file_location("network_matrix", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MatrixTests(unittest.TestCase):
    def test_plan_does_not_need_linux_or_root(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], check=True,
                                capture_output=True, text=True)
        plan = json.loads(result.stdout)
        self.assertFalse(plan["execute"])
        self.assertEqual(len(plan["cases"]), 3)
        self.assertEqual(plan["repeats"], 5)

    def test_reject_invalid_parameters(self):
        for args in (["--duration", "0"], ["--repeats", "0"], ["--execute"]):
            result = subprocess.run([sys.executable, str(SCRIPT), *args],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_parse_success(self):
        data = {"start": {"test_start": {"protocol": "TCP"}},
                "end": {"sender_tcp_congestion": "bbr",
                        "sum_received": {"bytes": 100, "bits_per_second": 800},
                        "sum_sent": {"retransmits": 2}}}
        self.assertEqual(MODULE.validate_iperf(data)["retransmits"], 2)
        data["end"]["sender_tcp_congestion"] = "cubic"
        with self.assertRaises(RuntimeError):
            MODULE.validate_iperf(data)
        data["end"]["sender_tcp_congestion"] = "bbr"
        data["end"]["sum_received"]["bytes"] = 0
        with self.assertRaises(RuntimeError):
            MODULE.validate_iperf(data)

    def test_server_error_is_not_success(self):
        with self.assertRaises(RuntimeError):
            MODULE.validate_iperf({"error": "connection refused"})


if __name__ == "__main__":
    unittest.main()
