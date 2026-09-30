# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx", "pydantic-settings", "anthropic>=1"]
# ///

import asyncio
import importlib.machinery
import importlib.util
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

loader = importlib.machinery.SourceFileLoader(
    "judge_eval", str(Path(__file__).resolve().parents[1] / "judge-eval")
)
spec = importlib.util.spec_from_loader(loader.name, loader)
judge = importlib.util.module_from_spec(spec)
loader.exec_module(judge)


class JudgeEvalTest(unittest.TestCase):
    def test_missing_settings_do_not_expose_other_credentials(self):
        with self.assertRaises(ValueError) as caught:
            judge.Settings(_env_file=None, cocore_api_key="private-test-marker", turso_url=None, turso_token=None)
        self.assertNotIn("private-test-marker", str(caught.exception))

    def test_local_endpoint_and_strict_boolean_verdict(self):
        responses = iter([
            '{"machine": false, "reason": "original writing"}',
            '{"machine": "false", "reason": "wrong type"}',
            '{"machine": null}',
            '{"machine": true} later {"machine": false, "reason": "final"}',
            None,
        ])
        auth = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                auth.append(self.headers.get("Authorization"))
                self.rfile.read(int(self.headers["Content-Length"]))
                body = json.dumps({"choices": [{"message": {"content": next(responses)}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        previous = os.environ.get("JUDGE_API_KEY")
        previous_url, previous_provider = judge.OPENAI_COMPAT_URL, judge.PROVIDER
        os.environ["JUDGE_API_KEY"] = ""
        judge.OPENAI_COMPAT_URL = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"
        judge.PROVIDER = "openai"

        async def run():
            settings = judge.Settings(_env_file=None, turso_url="unused", turso_token="unused", cocore_api_key="must-not-be-forwarded")
            async with httpx.AsyncClient() as client:
                return [await judge.ask(client, settings, "local", "sample") for _ in range(5)]

        try:
            results = asyncio.run(run())
            self.assertEqual([result[0] for result in results], [False, None, None, False, None])
            self.assertEqual(results[3][1], "final")
            self.assertEqual(auth, [None] * 5)
        finally:
            if previous is None:
                os.environ.pop("JUDGE_API_KEY")
            else:
                os.environ["JUDGE_API_KEY"] = previous
            judge.OPENAI_COMPAT_URL, judge.PROVIDER = previous_url, previous_provider
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == "__main__":
    unittest.main()
