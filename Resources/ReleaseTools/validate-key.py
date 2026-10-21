#!/usr/bin/env python3
"""Validate secret encoding without emitting it (even on malformed input)."""
import base64
import os
import sys

key = os.environ.get("SPARKLE_PRIVATE_ED_KEY", "")
try:
    decoded = base64.b64decode(key, validate=True)
    valid = len(decoded) in (32, 96) and base64.b64encode(decoded).decode() == key
except (ValueError, UnicodeError):
    valid = False
if not valid:
    sys.exit("ERROR: private signing key must be a canonical Sparkle base64 export (32 or 96 bytes), without whitespace.")
