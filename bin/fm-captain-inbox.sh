#!/usr/bin/env bash
# fm-captain-inbox.sh - narrow Captain's Inbox reader and explicit state updater.
#
# Usage:
#   fm-captain-inbox.sh list
#   fm-captain-inbox.sh mark <ci_v1_message_id> read|unread
#   fm-captain-inbox.sh delete <ci_v1_message_id>|read|unread
#   fm-captain-inbox.sh delete-ids read|unread <ci_v1_message_id> [<ci_v1_message_id> ...]
#
# Reads only the effective Firstmate home's private Captain's Inbox contract.
# It accepts no path arguments and delegates serialized JSON updates to Node's
# dependency-free standard-library implementation in fm-captain-inbox.mjs.
# Deletion is available only through explicit delete or delete-ids subcommands.
# docs/captain-inbox.md owns the confirmed-ID result and failure contract.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec node "$SCRIPT_DIR/fm-captain-inbox.mjs" "$@"
