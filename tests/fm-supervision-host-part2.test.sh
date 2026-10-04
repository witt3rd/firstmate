#!/usr/bin/env bash
# Second half of tests/fm-supervision-host.test.sh, split out so each half fits
# comfortably inside one CI shard (docs/fm-test-portable-shards.md).
set -u
FM_SUPERVISION_HOST_PART=2 exec "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh" "$@"
