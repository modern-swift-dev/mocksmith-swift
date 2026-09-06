#!/usr/bin/env python3

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


SITE_BASE = "/docs/mocksmith-swift/"


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str]] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        attribute = "href" if tag in {"a", "link"} else "src"
        if tag not in {"a", "link", "img", "script", "source"}:
            return

        for name, value in attrs:
            if name == attribute and value:
                self.links.append((tag, value))


def candidate_paths(path: Path) -> tuple[Path, Path, Path]:
    return (path, path.with_suffix(".html"), path / "index.html")


def resolve_link(root: Path, source: Path, value: str) -> Path | None:
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc or not parsed.path:
        return None

    decoded_path = unquote(parsed.path)
    if decoded_path == SITE_BASE.rstrip("/"):
        return root
    if decoded_path.startswith(SITE_BASE):
        return root / decoded_path.removeprefix(SITE_BASE)
    if decoded_path.startswith("/"):
        return root.parent / "__invalid_absolute_path__" / decoded_path.lstrip("/")
    return source.parent / decoded_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check local href and src targets in a static site."
    )
    parser.add_argument("site", type=Path, help="Assembled static-site directory")
    args = parser.parse_args()

    root = args.site.resolve()
    if not (root / "index.html").is_file():
        parser.error(f"site has no index.html: {root}")

    failures: list[str] = []
    checked = 0
    for source in sorted(root.rglob("*.html")):
        link_parser = LinkParser()
        try:
            link_parser.feed(source.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as error:
            failures.append(f"{source.relative_to(root)}: cannot read HTML: {error}")
            continue

        for _tag, value in link_parser.links:
            target = resolve_link(root, source, value)
            if target is None:
                continue
            checked += 1
            if not target.resolve().is_relative_to(root) or not any(
                candidate.is_file() for candidate in candidate_paths(target)
            ):
                failures.append(f"{source.relative_to(root)} -> {value}")

    if failures:
        print("Broken internal links:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"Checked {checked} internal links across {root}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
