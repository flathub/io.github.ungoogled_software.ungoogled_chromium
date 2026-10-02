#!/bin/sh
# Explicit SDK paths avoid recursion and flatpak-builder's optional ccache shims.
exec /app/bin/sccache "/usr/bin/${0##*/}" "$@"
