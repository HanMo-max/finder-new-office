#!/usr/bin/env python3
"""Check generated OOXML packages with the Python standard library.

This checks package structure and relationships, not full OOXML schemas.
"""
import posixpath
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

CONTENT_NS = "{http://schemas.openxmlformats.org/package/2006/content-types}"
OFFICE_BASE = "application/vnd.openxmlformats-officedocument."
REQUIRED = {
    ".docx": {"word/document.xml": OFFICE_BASE + "wordprocessingml.document.main+xml"},
    ".xlsx": {
        "xl/workbook.xml": OFFICE_BASE + "spreadsheetml.sheet.main+xml",
        "xl/worksheets/sheet1.xml": OFFICE_BASE + "spreadsheetml.worksheet+xml",
    },
    ".pptx": {
        "ppt/presentation.xml": OFFICE_BASE + "presentationml.presentation.main+xml",
        "ppt/slides/slide1.xml": OFFICE_BASE + "presentationml.slide+xml",
        "ppt/slideLayouts/slideLayout1.xml": OFFICE_BASE + "presentationml.slideLayout+xml",
        "ppt/slideMasters/slideMaster1.xml": OFFICE_BASE + "presentationml.slideMaster+xml",
        "ppt/theme/theme1.xml": OFFICE_BASE + "theme+xml",
    },
}


def check(path):
    with ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError("duplicate entries or invalid CRC")
        required = {"[Content_Types].xml", "_rels/.rels", *REQUIRED[path.suffix]}
        if not required.issubset(names):
            raise ValueError(f"missing package parts: {required - set(names)}")
        xml = {name: ET.fromstring(archive.read(name)) for name in names}
        types = {
            node.attrib["PartName"].lstrip("/"): node.attrib["ContentType"]
            for node in xml["[Content_Types].xml"].findall(CONTENT_NS + "Override")
        }
        for part, content_type in REQUIRED[path.suffix].items():
            if types.get(part) != content_type:
                raise ValueError(f"invalid content type: {part}")
        for name, document in xml.items():
            if not name.endswith(".rels"):
                continue
            base = "" if name == "_rels/.rels" else posixpath.dirname(posixpath.dirname(name))
            ids = set()
            for relationship in document:
                identifier = relationship.attrib["Id"]
                if identifier in ids:
                    raise ValueError(f"duplicate relationship ID: {name}: {identifier}")
                ids.add(identifier)
                if relationship.attrib.get("TargetMode") == "External":
                    continue
                target = relationship.attrib["Target"]
                resolved = posixpath.normpath(posixpath.join(base, target)).lstrip("/")
                if resolved not in names:
                    raise ValueError(f"missing relationship target: {name} -> {resolved}")
        if path.suffix == ".xlsx":
            sheets = xml["xl/workbook.xml"].findall("{*}sheets/{*}sheet")
            if len(sheets) != 1 or sheets[0].attrib.get("name") != "Sheet1":
                raise ValueError("expected one Sheet1 worksheet")
        if path.suffix == ".pptx":
            slides = xml["ppt/presentation.xml"].findall("{*}sldIdLst/{*}sldId")
            if len(slides) != 1:
                raise ValueError("expected one slide")
    print(f"package structure ok: {path.name}")


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        check(Path(argument))
