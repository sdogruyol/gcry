import copy
import unittest
import socket

from analyze import analyze, paired_ratios
from kemal_ab import parse_wrk, check_port


class MeasurementTest(unittest.TestCase):
    def rows(self):
        return [dict(arm=arm, round=i, rps=100.0 + i, requests=1000,
                     cpu_ticks=100, clk_tck=1000, hwm_kb=10, minflt=2)
                for arm in ("base", "candidate") for i in range(3)]

    def test_null_and_tick_conversion(self):
        result = analyze(self.rows(), "base")["candidate"]
        self.assertEqual((result["ratio"], result["ci_low"], result["ci_high"], result["t"]), (1, 1, 1, 0))
        self.assertEqual(result["cpu_ms_per_10k"], 1000)

    def test_ratio_test_matches_interval(self):
        result = paired_ratios([110, 240, 390], [100, 200, 300])
        self.assertAlmostEqual(result["ratio"], 1.2)
        self.assertAlmostEqual(result["t"], 3.464101615)
        self.assertLess(result["ci_low"], 1)

    def test_refuse_invalid_cost_pairs(self):
        for xs, ys in [([1, 2], [1]), ([1], [1]), ([1, float("nan")], [1, 2]),
                       ([1, 2], [0, 2]), ([1, float("inf")], [1, 2])]:
            with self.subTest(xs=xs, ys=ys), self.assertRaises(ValueError):
                paired_ratios(xs, ys)

    def test_wrk_latency_units(self):
        result = parse_wrk("100 requests in 1s\n  50% 900us\n  90% 1.5ms\n  99% 0.02s\n")
        self.assertEqual(result["latency_us"], {"p50": 900, "p90": 1500, "p99": 20000})

    def test_refuse_bad_trials(self):
        original = self.rows()
        variants = [original[:-1], original + [original[0]]]
        for key, value in [("error", "crash"), ("errors", {"timeout": 1}),
                           ("rps", 0), ("rps", float("nan")), ("cpu_ticks", -1)]:
            rows = copy.deepcopy(original)
            rows[0][key] = value
            variants.append(rows)
        for rows in variants:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                analyze(rows, "base")

    def test_port_check_handles_closed_connections(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
            listener.listen()
            with self.assertRaises(OSError):
                check_port(port)
            with socket.create_connection(("127.0.0.1", port)) as client:
                peer, _ = listener.accept()
                peer.close()
                self.assertEqual(client.recv(1), b"")
        check_port(port)

    def test_wrk_error_census(self):
        parsed = parse_wrk("1000 requests in 1.0s\nSocket errors: connect 1, read 2, write 3, timeout 4\nNon-2xx or 3xx responses: 5")
        self.assertEqual(parsed["requests"], 1000)
        self.assertEqual(sum(parsed["errors"].values()), 15)
        with self.assertRaises(ValueError):
            parse_wrk("0 requests in 1.0s")


if __name__ == "__main__":
    unittest.main()
