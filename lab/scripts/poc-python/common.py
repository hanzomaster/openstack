"""Shared helpers for OpenStack PoC scripts."""

import json
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import openstack

LOG_DIR = Path("/var/log/openstack-lab")


def setup_logging(script_name: str) -> Path:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_file = LOG_DIR / f"{script_name}.{ts}.log"

    LOG_DIR.mkdir(parents=True, exist_ok=True)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(sys.stdout),
        ],
    )
    openstack.enable_logging(debug=False)

    return log_file


def get_connection() -> openstack.connection.Connection:
    """Connect using OS_* env vars or clouds.yaml."""
    return openstack.connect(verify=False)


def banner(title: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    logging.info("=" * 50)
    logging.info(" %s  %s", title, ts)
    logging.info("=" * 50)


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, default=str))
    logging.info("wrote %s (%d bytes)", path, path.stat().st_size)
