#!/usr/bin/env python3

from __future__ import annotations

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


SITE_BASE = "/docs/mocksmith-swift"


class BasePathHandler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path in {"/", SITE_BASE}:
            self.send_response(301)
            self.send_header("Location", f"{SITE_BASE}/")
            self.end_headers()
            return
        super().do_GET()

    def translate_path(self, path: str) -> str:
        parsed = urlsplit(path)
        if not parsed.path.startswith(f"{SITE_BASE}/"):
            return str(Path(self.directory) / "__not_found__")

        original_path = self.path
        self.path = parsed.path.removeprefix(SITE_BASE)
        try:
            return super().translate_path(self.path)
        finally:
            self.path = original_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Preview the assembled Pages site.")
    parser.add_argument("site", type=Path, help="Assembled static-site directory")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    site = args.site.resolve()
    if not (site / "index.html").is_file():
        parser.error(f"site has no index.html: {site}")

    handler = partial(BasePathHandler, directory=str(site))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print(f"Serving {site} at http://127.0.0.1:{args.port}{SITE_BASE}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
