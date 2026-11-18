import importlib.util
from unittest.mock import patch
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "authorizer", Path(__file__).parents[1] / "authorizer/index.py"
)
authorizer = importlib.util.module_from_spec(spec)
with patch("pathlib.Path.read_text", return_value='["192.0.2.0/24", "2001:db8::/32"]'):
    spec.loader.exec_module(authorizer)


class SourceAllowlistTest(unittest.TestCase):
    def test_network_boundaries(self):
        for source in ("192.0.2.0", "192.0.2.255", "2001:db8::", "2001:db8:ffff::1"):
            with self.subTest(source=source):
                event = {"requestContext": {"http": {"sourceIp": source}}}
                self.assertEqual(authorizer.handler(event, None), {"isAuthorized": True})

    def test_outside_sources_and_spoofed_headers(self):
        for source in ("192.0.3.0", "2001:db9::1", "::ffff:192.0.2.1", "invalid"):
            with self.subTest(source=source):
                event = {
                    "requestContext": {"http": {"sourceIp": source}},
                    "headers": {"x-forwarded-for": "192.0.2.1", "authorization": "anything"},
                }
                self.assertEqual(authorizer.handler(event, None), {"isAuthorized": False})

    def test_malformed_context_is_denied(self):
        for event in ({}, None, {"requestContext": None}):
            self.assertEqual(authorizer.handler(event, None), {"isAuthorized": False})

    def test_tokens_are_left_to_opsrabbit(self):
        for headers in ({}, {"x-opsrabbit-webhook-token": "incorrect"}):
            event = {"requestContext": {"http": {"sourceIp": "192.0.2.1"}}, "headers": headers}
            self.assertEqual(authorizer.handler(event, None), {"isAuthorized": True})


if __name__ == "__main__":
    unittest.main()
