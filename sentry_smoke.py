import os
import sys

import sentry_sdk

# The DSN is read from the environment; it must never be committed.
dsn = os.environ.get("SENTRY_DSN", "").strip()
if not dsn:
    sys.exit(
        "SENTRY_DSN is not set. Set it to the project's DSN "
        "(Sentry: Project Settings > Client Keys (DSN)) and run again."
    )

sentry_sdk.init(
    dsn=dsn,
    traces_sample_rate=1.0,
    environment="ci",
    release="atomarcade-bridge@0.0.1",
)
sentry_sdk.capture_message("AtomArcade Bridge online ✅ (smoke test)")
try:
    raise ZeroDivisionError("smoke test")
except ZeroDivisionError as e:
    sentry_sdk.capture_exception(e)
sentry_sdk.flush(timeout=5)
