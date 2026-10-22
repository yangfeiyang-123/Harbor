#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -u Tests/code_workbench_test.py -v
for test_file in Tests/code_workbench_*_test.js; do
    node "$test_file"
done
