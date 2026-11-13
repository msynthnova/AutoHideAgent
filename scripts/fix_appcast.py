#!/usr/bin/env python3
"""Keep each archive and delta attached to its own GitHub release tag."""
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
path = sys.argv[1]
tree = ET.parse(path)
for item in tree.findall("./channel/item"):
    version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
    if not version:
        raise ValueError("Missing release version in appcast")
    for enclosure in item.iter("enclosure"):
        filename = urlsplit(enclosure.attrib["url"]).path.rsplit("/", 1)[-1]
        enclosure.set("url", f"https://github.com/msynthnova/AutoHideAgent/releases/download/v{version}/{filename}")
tree.write(path, encoding="utf-8", xml_declaration=True)
