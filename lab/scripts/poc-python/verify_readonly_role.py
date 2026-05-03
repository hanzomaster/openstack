#!/usr/bin/env python3
"""Verify the readonly-auditor role: read operations succeed, writes are denied.

Run AFTER:
  1. python3 readonly_role.py
  2. kolla-ansible -i ~/kolla-inventory reconfigure

Authenticates as the 'auditor' user with the readonly-auditor role
on demo-proj, then runs a suite of read/write tests against each service.
"""

import logging
import os
import sys
from dataclasses import dataclass

import openstack

from common import banner, setup_logging

log = logging.getLogger(__name__)

DEMO_PASSWORD = "Pass123!"


@dataclass
class TestResult:
    service: str
    operation: str
    kind: str  # "READ" or "WRITE"
    passed: bool
    detail: str


def get_auditor_connection() -> openstack.connection.Connection:
    admin_auth_url = os.environ.get("OS_AUTH_URL", "")
    if not admin_auth_url:
        log.error("OS_AUTH_URL not set — source admin-openrc.sh first")
        sys.exit(1)

    return openstack.connect(
        auth_url=admin_auth_url,
        username="auditor",
        password=DEMO_PASSWORD,
        project_name="demo-proj",
        user_domain_name="Default",
        project_domain_name="Default",
        identity_api_version="3",
        verify=False,
    )


def expect_success(conn, service: str, operation: str, fn) -> TestResult:
    try:
        fn(conn)
        return TestResult(service, operation, "READ", True, "OK")
    except Exception as e:
        return TestResult(service, operation, "READ", False, str(e)[:120])


def expect_denied(conn, service: str, operation: str, fn) -> TestResult:
    try:
        fn(conn)
        return TestResult(service, operation, "WRITE", False,
                          "should have been denied but succeeded")
    except Exception as e:
        msg = str(e).lower()
        if any(kw in msg for kw in ("403", "forbidden", "not authorized", "policy")):
            return TestResult(service, operation, "WRITE", True, "DENIED (expected)")
        return TestResult(service, operation, "WRITE", False, f"error but not 403: {str(e)[:100]}")


def run_tests(conn) -> list[TestResult]:
    results = []

    # -- Keystone --
    results.append(expect_success(conn, "Keystone", "project list",
                                  lambda c: list(c.identity.projects())))
    results.append(expect_success(conn, "Keystone", "user list",
                                  lambda c: list(c.identity.users())))
    results.append(expect_success(conn, "Keystone", "role list",
                                  lambda c: list(c.identity.roles())))
    results.append(expect_success(conn, "Keystone", "endpoint list",
                                  lambda c: list(c.identity.endpoints())))
    results.append(expect_denied(conn, "Keystone", "project create",
                                 lambda c: c.identity.create_project(name="test-deny-proj")))

    # -- Nova --
    results.append(expect_success(conn, "Nova", "server list",
                                  lambda c: list(c.compute.servers())))
    results.append(expect_success(conn, "Nova", "flavor list",
                                  lambda c: list(c.compute.flavors())))
    results.append(expect_success(conn, "Nova", "hypervisor list",
                                  lambda c: list(c.compute.hypervisors())))
    results.append(expect_success(conn, "Nova", "AZ list",
                                  lambda c: list(c.compute.availability_zones())))
    results.append(expect_denied(conn, "Nova", "server create",
                                 lambda c: c.compute.create_server(
                                     name="test-deny-vm", flavor_id="1",
                                     image_id="nonexistent")))

    # -- Neutron --
    results.append(expect_success(conn, "Neutron", "network list",
                                  lambda c: list(c.network.networks())))
    results.append(expect_success(conn, "Neutron", "subnet list",
                                  lambda c: list(c.network.subnets())))
    results.append(expect_success(conn, "Neutron", "router list",
                                  lambda c: list(c.network.routers())))
    results.append(expect_success(conn, "Neutron", "security group list",
                                  lambda c: list(c.network.security_groups())))
    results.append(expect_denied(conn, "Neutron", "network create",
                                 lambda c: c.network.create_network(name="test-deny-net")))

    # -- Cinder --
    results.append(expect_success(conn, "Cinder", "volume list",
                                  lambda c: list(c.block_storage.volumes())))
    results.append(expect_success(conn, "Cinder", "volume type list",
                                  lambda c: list(c.block_storage.types())))
    results.append(expect_denied(conn, "Cinder", "volume create",
                                 lambda c: c.block_storage.create_volume(size=1,
                                     name="test-deny-vol")))

    # -- Glance --
    results.append(expect_success(conn, "Glance", "image list",
                                  lambda c: list(c.image.images())))
    results.append(expect_denied(conn, "Glance", "image create",
                                 lambda c: c.image.create_image(
                                     name="test-deny-img", disk_format="qcow2",
                                     container_format="bare")))

    return results


def main() -> None:
    log_file = setup_logging("verify-readonly-role")
    banner("verify_readonly_role.py")

    conn = get_auditor_connection()

    log.info("")
    log.info("=== Testing as auditor (readonly-auditor role on demo-proj) ===")

    results = run_tests(conn)

    current_service = ""
    for r in results:
        if r.service != current_service:
            log.info("")
            log.info("--- %s ---", r.service)
            current_service = r.service

        status = "OK" if r.passed else "FAIL"
        log.info("  [%-5s] %-25s %s  %s", r.kind, r.operation, status, r.detail)

    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    total = len(results)

    log.info("")
    log.info("=" * 50)
    log.info(" RESULTS: %d/%d passed, %d/%d failed", passed, total, failed, total)
    log.info("=" * 50)

    if failed > 0:
        log.info("")
        log.info("Some tests failed. Check that you ran 'kolla-ansible reconfigure'")
        log.info("after readonly_role.py and that services restarted cleanly.")
        sys.exit(1)

    log.info("")
    log.info("All tests passed. The readonly-auditor role is working correctly.")
    log.info("Log at: %s", log_file)


if __name__ == "__main__":
    main()
