#!/usr/bin/env python3
"""A narrow regression tripwire, not a substitute for security review."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
forbidden = {
    r"\bimport\s+(WebKit|AVFoundation|JavaScriptCore|PDFKit|QuickLook|LinkPresentation)\b": "rich-content framework",
    r"\b(WKWebView|WebView|NSImageView|AVPlayer|JSContext|QLPreviewPanel)\b": "rich-content view",
    r"NSAttributedString\s*\([^)]*(html|documentType)": "rich document parsing",
    r"NSWorkspace\.shared\.open\s*\(": "automatic external opening",
    r"\bURLSession\b": "direct network client (use the official service)",
    r"/bin/(ba)?sh": "shell execution",
}
issues = []
for path in (root / "Sources").rglob("*"):
    if path.suffix not in {".swift", ".c", ".h"}:
        continue
    data = path.read_text()
    for expression, reason in forbidden.items():
        if re.search(expression, data):
            issues.append(f"{path.relative_to(root)}: {reason}")
if issues:
    print("\n".join(issues))
    sys.exit(1)
print("Surface tripwire passed: no listed media, browser, direct networking, or shell entry points.")
