#!/bin/bash
set -euo pipefail

# /tmp is private to the build sandbox. Run even when Flatpak reuses the
# sccache module, but avoid repeating migration for every compiler invocation.
ready=/tmp/ungoogled-chromium-sccache-ready
if [[ ! -e "${ready}" ]]; then
    (
        flock -x 9
        if [[ ! -e "${ready}" ]]; then
            # Only ccache's legacy hash buckets and temporary data. Preserve
            # sccache/, ccache.conf, and Flatpak's bin/ and disabled/ helpers.
            rm -rf -- /run/ccache/[0-9a-f] /run/ccache/tmp
            touch "${ready}"
        fi
    ) 9>/tmp/ungoogled-chromium-sccache-migration.lock
fi

exec /app/libexec/sccache-bin/sccache "$@"
