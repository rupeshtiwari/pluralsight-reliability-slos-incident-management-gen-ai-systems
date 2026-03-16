#!/usr/bin/env bash
# Scene 5 — SLO Validation
set -uo pipefail

echo "--- Availability SLO ---"
curl -s -G "localhost:9090/api/v1/query" --data-urlencode "query=genai_slo_availability_ratio" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['data']['result']
    if r:
        print('Availability SLO:', r[0]['value'][1])
    else:
        print('no data')
except Exception as e:
    print('error:', e)
"

echo ""
echo "--- P99 Latency ---"
curl -s -G "localhost:9090/api/v1/query" --data-urlencode "query=histogram_quantile(0.99, rate(genai_request_duration_seconds_bucket[5m]))" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['data']['result']
    if r:
        val = float(r[0]['value'][1])
        print('P99 latency:', round(val, 3), 'seconds')
    else:
        print('no data')
except Exception as e:
    print('error:', e)
"