#!/usr/bin/env python3
"""PoC 2 — Detect orphaned users (no project role assignments).

Queries Keystone for all users and role assignments, then reports
users who have no project-scoped role. Optionally posts results
to a Mattermost incoming webhook.

Set MATTERMOST_WEBHOOK_URL env var to enable Mattermost posting.

Why openstacksdk:
  1. Direct access to role_assignments with include_names=True.
  2. No JSON parsing fragility — SDK returns typed objects.
  3. Easy to filter by scope (project vs domain vs system).
"""

import json
import logging
import os
from dataclasses import dataclass

import requests

from common import banner, get_connection, setup_logging

log = logging.getLogger(__name__)

SERVICE_ACCOUNTS = frozenset({
    "nova", "neutron", "cinder", "glance", "heat", "placement", "keystone",
    "barbican", "octavia", "designate", "manila", "aodh", "gnocchi",
    "ceilometer", "swift", "magnum", "trove", "sahara", "ironic",
    "cloudkitty", "monasca", "panko", "blazar", "freezer", "karbor",
    "mistral", "murano", "senlin", "tacker", "vitrage", "watcher", "zun",
})

SKIP_USERS = SERVICE_ACCOUNTS | {"admin"}


@dataclass(frozen=True)
class OrphanedUser:
    id: str
    name: str
    enabled: bool


def find_orphaned_users(conn) -> list[OrphanedUser]:
    log.info("[gather] listing users")
    all_users = list(conn.identity.users())

    log.info("[gather] listing role assignments")
    assignments = list(conn.identity.role_assignments())

    users_with_projects: set[str] = set()
    for assignment in assignments:
        scope = assignment.get("scope", {})
        if "project" in scope:
            users_with_projects.add(assignment.get("user", {}).get("id", ""))

    log.info("[compute] %d users, %d assignments, %d with project roles",
             len(all_users), len(assignments), len(users_with_projects))

    orphaned = []
    for user in all_users:
        if user.name.lower() in SKIP_USERS:
            continue
        if user.id not in users_with_projects:
            orphaned.append(OrphanedUser(
                id=user.id,
                name=user.name,
                enabled=user.is_enabled,
            ))

    return orphaned


def format_report(orphans: list[OrphanedUser]) -> str:
    if not orphans:
        return "**Orphaned User Scan** — no orphaned users found."

    lines = [
        f"**Orphaned User Scan** — found {len(orphans)} user(s) with no project role assignments:\n",
        "| User | ID | Status |",
        "|------|----|----|",
    ]
    for user in orphans:
        status = "enabled" if user.enabled else "disabled"
        lines.append(f"| `{user.name}` | `{user.id}` | {status} |")

    return "\n".join(lines)


def post_to_mattermost(webhook_url: str, text: str) -> None:
    log.info("[mattermost] posting to webhook")
    resp = requests.post(webhook_url, json={"text": text}, timeout=30)
    if resp.ok:
        log.info("  posted successfully (HTTP %d)", resp.status_code)
    else:
        log.warning("  Mattermost returned HTTP %d: %s", resp.status_code, resp.text)


def main() -> None:
    log_file = setup_logging("orphaned-users")
    banner("orphaned_users.py")

    conn = get_connection()
    orphans = find_orphaned_users(conn)

    log.info("")
    log.info("=== ORPHANED USERS (%d) ===", len(orphans))
    if not orphans:
        log.info("  (none found)")
    else:
        for user in orphans:
            status = "enabled" if user.enabled else "disabled"
            log.info("  - %s  (id=%s, %s)", user.name, user.id, status)

    report = format_report(orphans)

    webhook_url = os.environ.get("MATTERMOST_WEBHOOK_URL", "")
    if webhook_url:
        post_to_mattermost(webhook_url, report)
    else:
        log.info("")
        log.info("[mattermost] MATTERMOST_WEBHOOK_URL not set — skipping post")
        log.info("  To enable: export MATTERMOST_WEBHOOK_URL=https://mm.example.com/hooks/xxx")

    log.info("")
    log.info("Orphaned user scan complete. Log at: %s", log_file)


if __name__ == "__main__":
    main()
