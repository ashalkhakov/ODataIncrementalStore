#!/bin/sh
# Bring up the OIS workbench. Idempotent: skip if already healthy.
if curl -sf -o /dev/null http://127.0.0.1:8080/; then
  exit 0
fi
cd /workspace || exit 1
npm run dev > /tmp/ois-dev.log 2>&1 &
exit 0
