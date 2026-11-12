#!/usr/bin/env python3
# Lists the tests in a result bundle that failed only by running out of time, one per line, as xcodebuild's
# -only-testing takes them. Used by CI (.github/workflows/build.yml), where decoding video sometimes stalls for good,
# to run those tests once more. Exits with 1 when a test failed some other way, or none failed.
#
# Usage: Scripts/stalled-tests.py build/TestResults.xcresult

import json
import subprocess
import sys

summary = json.loads(subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1]],
    check=True, capture_output=True, text=True,
).stdout)

stalled, failed = [], []
for failure in summary.get("testFailures", []):
    test = f"{failure['targetName']}/{failure['testIdentifierString']}"
    text = failure.get("failureText", "")
    timed_out = "exceeded execution time allowance" in text or "Time limit was exceeded" in text
    (stalled if timed_out else failed).append(test)

if failed or not stalled:
    for test in dict.fromkeys(failed):
        print(f"{test} failed", file=sys.stderr)
    sys.exit(1)
print("\n".join(dict.fromkeys(stalled)))
