import json
import platform
import sys
from datetime import datetime, timezone

result = {
    "ok": True,
    "tool": "viktor.test",
    "message": "Hello from HomeBase -> Viktor script target",
    "python": sys.version,
    "platform": platform.platform(),
    "argv": sys.argv[1:],
    "ts": datetime.now(timezone.utc).isoformat(),
}
print(json.dumps(result, indent=2))
