#!/usr/bin/env python3

import argparse
import http.client
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

REAL_HOST_HEADER = "x-wuhu-ai-real-host"


def load_config(path: Path) -> dict[str, dict[str, str]]:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


class ForwardProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "WuhuAILLMForwardProxy/0.1"

    def do_GET(self):
        self._handle_request()

    def do_POST(self):
        self._handle_request()

    def do_PUT(self):
        self._handle_request()

    def do_PATCH(self):
        self._handle_request()

    def do_DELETE(self):
        self._handle_request()

    def do_OPTIONS(self):
        self._handle_request()

    def _handle_request(self):
        real_host = self.headers.get(REAL_HOST_HEADER)
        if not real_host:
            self.send_error(400, f"Missing required header: {REAL_HOST_HEADER}")
            return

        host_config = self.server.host_config.get(real_host)
        if host_config is None:
            self.send_error(502, f"No forwarding config for host: {real_host}")
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        request_body = self.rfile.read(content_length) if content_length else b""

        outgoing_headers = {}
        for name, value in self.headers.items():
            lowered = name.lower()
            if lowered in {"host", "content-length", REAL_HOST_HEADER.lower()}:
                continue
            outgoing_headers[name] = value

        outgoing_headers[host_config["header"]] = host_config["value"]

        split = urlsplit(self.path)
        path = split.path or "/"
        if split.query:
            path = f"{path}?{split.query}"

        connection = http.client.HTTPSConnection(real_host)
        try:
            connection.request(
                self.command,
                path,
                body=request_body,
                headers=outgoing_headers,
            )
            response = connection.getresponse()
            response_body = response.read()

            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() == "transfer-encoding":
                    continue
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            if response_body:
                self.wfile.write(response_body)
        finally:
            connection.close()


class ForwardProxyServer(ThreadingHTTPServer):
    def __init__(self, server_address, handler_class, host_config):
        super().__init__(server_address, handler_class)
        self.host_config = host_config


def main() -> None:
    parser = argparse.ArgumentParser(description="Forward localhost LLM requests to real upstream hosts")
    parser.add_argument(
        "--config",
        default="AlignedTargets/AI/Tests/IntegrationTests/llm-forward-proxy.config.json",
        help="Path to the forwarding config JSON",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11451)
    args = parser.parse_args()

    config = load_config(Path(args.config))
    server = ForwardProxyServer((args.host, args.port), ForwardProxyHandler, config)

    print(f"Listening on http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
