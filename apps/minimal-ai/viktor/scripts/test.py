#!/usr/bin/env python3
"""
viktor/scripts/test.py
Canonical HomeBase hello script.
Usage: python test.py --hello homebase
"""
import json
import sys

args = sys.argv[1:]
if "--hello" in args:
    print(json.dumps({
        "ok": True,
        "tool": "viktor.test",
        "message": "Hello from HomeBase -> Viktor script target",
        "args": args,
    }))
else:
    print(json.dumps({"ok": False, "error": "Pass --hello homebase to run the test."}))
    sys.exit(1)
