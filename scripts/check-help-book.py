#!/usr/bin/env python3
"""Validate a generated Mac Help Book and its native search index before signing."""
from html.parser import HTMLParser
from pathlib import Path
import plistlib
import subprocess
import sys
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.anchors = set()
        self.links = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "a" and values.get("name"):
            self.anchors.add(values["name"])
        for name in ("href", "src"):
            if values.get(name):
                self.links.append(values[name])


def check(book):
    app_info = None
    if book.suffix == ".app":
        app_info = plistlib.loads((book / "Contents/Info.plist").read_bytes())
        if (app_info.get("CFBundleHelpBookFolder") != "Driftbox.help"
                or app_info.get("CFBundleHelpBookName") != "app.driftbox.native.help"):
            raise ValueError("The app does not register the Driftbox Help Book")
        book = book / "Contents/Resources/Driftbox.help"
    info = plistlib.loads((book / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "app.driftbox.native.help" or info.get("HPDBookType") != "3":
        raise ValueError("Incorrect Help Book registration metadata")
    if app_info:
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if info.get(key) != app_info[key]:
                raise ValueError(f"Help Book {key} differs from the app")
    language = book / "Contents/Resources/en.lproj"
    for key in ("HPDBookAccessPath", "HPDBookIndexPath"):
        value = info[key]
        if Path(value).name != value or not (language / value).is_file():
            raise ValueError(f"Missing or unsafe {key}: {value}")
    pages = {path.name: Page(path) for path in language.glob("*.html")}
    if not pages:
        raise ValueError("The Help Book has no pages")
    anchors = set()
    for name, page in pages.items():
        if anchors.intersection(page.anchors):
            raise ValueError(f"Duplicate help anchor in {name}")
        anchors.update(page.anchors)
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                raise ValueError(f"Help must work offline: {link}")
            target = (language / unquote(url.path)).resolve() if url.path else language / name
            if not target.is_relative_to(language.resolve()) or not target.is_file():
                raise ValueError(f"Broken local link in {name}: {link}")
            if url.fragment and unquote(url.fragment) not in pages[target.name].anchors:
                raise ValueError(f"Missing link anchor in {name}: {link}")
    index = language / info["HPDBookIndexPath"]
    if not index.stat().st_size:
        raise ValueError("Empty help search index")

    def inspect(mode):
        return subprocess.check_output(
            ["/usr/bin/hiutil", "-I", "corespotlight", mode, "-f", str(index)], text=True)

    indexed_anchors = set(inspect("-A").splitlines())
    if anchors != indexed_anchors:
        raise ValueError(f"Help index anchors differ from pages: {anchors ^ indexed_anchors}")
    indexed_files = {Path(urlsplit(line).path).name for line in inspect("-F").splitlines()}
    if set(pages) != indexed_files:
        raise ValueError(f"Help index pages differ from content: {set(pages) ^ indexed_files}")
    print(f"Help Book verified: {len(pages)} pages, {len(anchors)} anchors, local links and native index.")


if __name__ == "__main__":
    check(Path(sys.argv[1]))
