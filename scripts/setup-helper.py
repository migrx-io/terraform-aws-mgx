#!/usr/bin/env python3
import uuid
import psutil
import sys
import requests
import json
import os
import time


DATA_IPS_FILE = "../storage_data_ips.txt"
MGMT_IPS_FILE = "../storage_mgmt_ips.txt"
SECRETS_FILE = "../secrets.env"
ENVS_FILE = "./mgx-env"
SPDK_ENV = "./mgx-spdk"
MERGED_ENV_FILE = "/etc/mgx-env"
MANIFEST_FILE = "./cache.yaml"
GEN_MANIFEST_FILE = "./gen_cache.yaml"
MANIFEST_FILE_S = "./storage.yaml"
GEN_MANIFEST_FILE_S = "./gen_stotage.yaml"
POOL_INFO_FILE= "../pool_info.json"
MANIFEST_FILE_SRV = "./systemd.yaml"
MANIFEST_FILE_MGMT = "./mgmt.yaml"
MANIFEST_FILE_MGMT_POOL = "./mgmt-pool.yaml"
GEN_MANIFEST_FILE_MGMT = "./gen_mgmt.yaml"

# Collect all IPv4 addresses from all interfaces
def get_all_ips():
    local_ips = set()
    for iface, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family.name == 'AF_INET':  # IPv4
                local_ips.add(addr.address)
    return local_ips


def mgx_id():
    # Read the storage data IPs
    with open(DATA_IPS_FILE, "r") as f:
        data_ips = [line.strip() for line in f if line.strip()]

    # Compare and generate UUID5 for matching IP
    for ip in data_ips:
        if ip in get_all_ips():
            node_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, ip)
            print(f"{node_uuid}")


def is_first_node():

    # Read the storage data IPs
    with open(DATA_IPS_FILE, "r") as f:
        data_ips = [line.strip() for line in f if line.strip()]

    first_ip = data_ips[0]
    if first_ip in get_all_ips():
        return True

    return False


def mgx_hosts():
    # Read the storage data IPs
    with open(MGMT_IPS_FILE, "r") as f:
        mgmt_ips = "\n".join([line.strip() for line in f if line.strip()])

        print(f"{mgmt_ips}")


def read_env_file(path):
    env_vars = {}
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip('"')
    return env_vars


def mgx_env():

    # Load env files
    base_env = read_env_file(ENVS_FILE)
    secrets_env = read_env_file(SECRETS_FILE)

    # Merge with secrets taking precedence
    merged_env = {**base_env, **secrets_env}

    # Detect current node's management IP
    local_ips = get_all_ips()
    with open(MGMT_IPS_FILE, "r") as f:
        mgmt_ips = [line.strip() for line in f if line.strip()]

    iface = None
    current_mgmt_ip = None

    for iface_name, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family.name == 'AF_INET' and addr.address in mgmt_ips:
                iface = iface_name
                current_mgmt_ip = addr.address
                break
        if iface:
            break

    # If found, set MGX_IFACE
    if iface:
        merged_env["MGX_IFACE"] = iface
        merged_env["CASS_RPC_ADDR"] = current_mgmt_ip
    else:
        raise Exception("iface not found")

    # Set MGX_CASS_CREDS using CASS_USER and CASS_PASSWD
    cass_user = merged_env.get("CASS_USER", "<CASS_USER>")
    cass_pass = merged_env.get("CASS_PASSWD", "<CASS_PASSWD>")
    merged_env["MGX_CASS_CREDS"] = f"{cass_user}:{cass_pass}"

    # Output final merged env
    for k, v in merged_env.items():
        print(f"{k}={v}")


def mgx_cass_seeds():
    # Read the first two IPs from MGMT_IPS_FILE
    with open(MGMT_IPS_FILE, "r") as f:
        mgmt_ips = [line.strip() for line in f if line.strip()]

    # Prepare seeds string
    seeds_value = ",".join(f"{ip}" for ip in mgmt_ips)

    print(seeds_value)


def mgx_cass_nodes_count():
    # Read the first two IPs from MGMT_IPS_FILE
    with open(MGMT_IPS_FILE, "r") as f:
        mgmt_ips = [line.strip() for line in f if line.strip()]

    print(len(mgmt_ips))


def mgx_storage_vol_count():

    # Load pool info JSON
    d = {}
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    print(d.get("config", {}).get("max_volumes_count", 16))


def mgx_spdk():

    # Load pool info JSON
    d = {}
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    with open(SPDK_ENV, "r") as f:
        data = f.read()

    # Replace placeholders in data
    data = data.replace("<region>", d["region"])
    data = data.replace("<pool>", d["pool_name"])

    print(data)

def cache_type():

    # Load pool info JSON
    d = {}
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    # raid_level == 0 means the pool uses EBS volumes striped into a single
    # mdadm RAID0 cache (no SPDK cache service); any other level is local NVMe.
    if d.get("config", {}).get("raid_level") == 0:
        print("ebs")
    else:
        print("nvme")


def is_metrics_enabled():

    # Load pool info JSON
    d = {}
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    print(d.get("config", {}).get("enable_metrics"))


def is_grafana_enabled():

    d = {}
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    return d.get("config", {}).get("enable_grafana")


def is_cross_peer_scrape():
    """Whether this pool's nodes scrape each other (full per-pool replica).
    Defaults to True (standalone pool). Set false when mgmt scrapes every node
    directly, so each node only scrapes its own metrics."""

    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    print(d.get("config", {}).get("cross_peer_scrape", True))


def prometheus_federate():
    """Emit each mgmt node's federation jobs, one per downstream storage pool.

    Federation is endpoint-agnostic: a pool node's own prometheus already
    scrapes every local endpoint (/metrics, /plugin/metrics, ...), so pulling
    {job=~".+"} via /federate re-exports all of it without mgmt knowing the
    paths.

    cross_peer_scrape=false (mgmt-attached pools): each node holds only its own
    series, so mgmt federates from EVERY node - the union is exact (no dupes),
    with no node-selection SPOF. A per-node 'node' label keeps series distinct
    even when a node scrapes itself as localhost.

    cross_peer_scrape=true (standalone replica left attached): every node holds
    the whole pool, so we federate from a single node (the first) to avoid
    duplicate series."""

    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    blocks = []
    for name, pool in (d.get("pools") or {}).items():
        node_ips = pool.get("node_ips") or []
        if not node_ips:
            continue

        # The stock Node Exporter Full dashboard keys every panel off the
        # 'instance' label, but each node scrapes its own node_exporter as
        # localhost:9100 - so every node's series share instance=localhost:9100
        # and collapse into one. In the per-node case below we tag each target
        # with a distinct 'node' label and rewrite 'instance' from it, so nodes
        # stay separable. The full-replica case keeps distinct instances already.
        relabel = ""
        if pool.get("cross_peer_scrape", True):
            # Full replica: one node already has the whole pool's series.
            groups = """      - targets: ['{ip}:9090']
        labels:
          pool: '{name}'""".format(ip=node_ips[0], name=name)
        else:
            # Each node holds only its own series: federate them all, tagging
            # each target with its node so localhost instances don't collide.
            groups = "\n".join("""      - targets: ['{ip}:9090']
        labels:
          pool: '{name}'
          node: '{ip}'""".format(ip=ip, name=name) for ip in node_ips)
            relabel = """
    metric_relabel_configs:
      - source_labels: [node]
        target_label: instance"""

        blocks.append("""
  - job_name: 'federate-{name}'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{{job=~".+"}}'
    static_configs:
{groups}{relabel}""".format(name=name, groups=groups, relabel=relabel))

    print("\n".join(blocks))

def generate_cache_yaml():

    # Load pool info JSON
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    # Load cache template
    with open(MANIFEST_FILE, "r") as f:
        template = f.read()

    # Load storage template
    with open(MANIFEST_FILE_S, "r") as f:
        template_s = f.read()

    # Prepare values
    values = d["config"]
    values["name"] = d["pool_name"]

    # EBS pools carry an owner->[volume-ids] map (terraform); render it as a
    # JSON string so the cache config stores it verbatim.
    values["cache_volumes"] = json.dumps(values.get("cache_volumes") or {})

    # Read storage data IPs
    with open(DATA_IPS_FILE, "r") as f:
        ips = [line.strip() for line in f if line.strip()]

    # Generate UUIDv5 for each IP
    node_entries = []
    for ip in ips:
        u = uuid.uuid5(uuid.NAMESPACE_DNS, ip)
        node_entries.append(f"{u}:{ip}")

    # Add to values
    values["node_ips"] = "[" + ", ".join(f'"{entry}"' for entry in node_entries) + "]"
    values["s3_buckets"] = values["s3_bucket_names"]
    # Storage bucket: use the first configured storage bucket.
    storage_buckets = values.get("s3_bucket_names") or []
    values["s3_bucket"] = storage_buckets[0]
    # Snapshot dst_bucket: use the dedicated backup bucket when configured,
    # otherwise fall back to the storage bucket.
    backup_buckets = values.get("s3_backup_bucket_names") or []
    values["s3_backup_bucket"] = (
        backup_buckets[0] if backup_buckets else values["s3_bucket"]
    )

    # Format template
    rendered = template.format(**values)

    # generate storage/scheduler/snapshot config for volumes; name them after
    # the pool so each pool's configs are unique on the management side.
    rendered_s = template_s.format(**{
        "name": values["name"],
        "s3_bucket_name": values["s3_bucket"],
        "s3_backup_bucket": values["s3_backup_bucket"],
    })

    # Save next to cache.yaml
    with open(GEN_MANIFEST_FILE, "w") as f:
        f.write(rendered)

    with open(GEN_MANIFEST_FILE_S, "w") as f:
        f.write(rendered_s)


def generate_mgmt_yaml():

    # Load pool info JSON
    with open(POOL_INFO_FILE, "r") as f:
        d = json.load(f)

    cfg = d.get("config", {})

    # Header: aaa namespace + mgmt behavior config (default)
    with open(MANIFEST_FILE_MGMT, "r") as f:
        header = f.read().format(
            pull_http_timeout=cfg.get("pull_http_timeout", 30),
            push_http_timeout=cfg.get("push_http_timeout", 30),
        )

    # One pool_add block per downstream storage pool
    with open(MANIFEST_FILE_MGMT_POOL, "r") as f:
        pool_tmpl = f.read()

    docs = [header]
    for name, pool in (d.get("pools") or {}).items():
        # node_ips are seed API addresses of the pool's nodes (plain IPs;
        # the mgmt plugin reaches them on MGX_PORT). Render as a YAML list.
        node_ips = "[" + ", ".join(
            f'"{ip}"' for ip in (pool.get("node_ips") or [])
        ) + "]"
        docs.append(pool_tmpl.format(
            name=name,
            node_ips=node_ips,
            descr=pool.get("descr") or "",
            labels=pool.get("labels") or "",
        ))

    with open(GEN_MANIFEST_FILE_MGMT, "w") as f:
        f.write("\n---\n".join(docs))


def _gw_session():
    """Authenticate against the local gateway and return (session, host,
    auth_headers)."""

    merged_env = read_env_file(MERGED_ENV_FILE)

    host = "http://{}:{}".format(merged_env["CASS_RPC_ADDR"], merged_env["MGX_GW_PORT"])
    password = merged_env["MGX_GW_ADMIN_PASSWD"]

    session = requests.Session()
    headers = {"accept": "application/json", "Content-Type": "application/json"}

    resp = session.post(f"{host}/api/v1/auth", headers=headers, json={
        "cluster": "main",
        "ns": "main",
        "username": "admin",
        "password": password,
    })
    if resp.status_code != 200:
        print(f"❌ Auth failed! Status code: {resp.status_code}")
        raise Exception(resp.text)

    access_token = resp.json().get("access_token")
    if not access_token:
        print("❌ Failed to extract access_token")
        raise Exception("No found token")

    auth_headers = {"accept": "application/json", "Authorization": f"JWT {access_token}"}
    return session, host, auth_headers


def _ensure_cluster(session, host, auth_headers, nodes_count):
    """Create the main cluster if needed and join free nodes until the cluster
    holds nodes_count members. Raises 'Not ready' until it does."""

    # Get cluster list
    resp = session.get(f"{host}/api/v1/cluster", headers=auth_headers)
    if resp.status_code not in (200, 201):
        raise Exception(resp.text)

    if len(resp.json()) == 0:
        # Create cluster if not exist
        resp = session.post(f"{host}/api/v1/cluster/main", headers=auth_headers,
                            json={"node_ids": ["*"], "vip": "127.0.0.1"})
        if resp.status_code in (200, 201):
            print(f"✅ Cluster create success! Status code: {resp.status_code}")
        else:
            raise Exception(resp.text)

    # Get cluster nodes
    resp = session.get(f"{host}/api/v1/cluster/main/nodes", headers=auth_headers)
    if resp.status_code not in (200, 201):
        raise Exception(resp.text)

    if len(resp.json()) != nodes_count:
        print("❌ Not enough nodes in main cluster {} != {}".format(
            len(resp.json()), nodes_count))

        # Add free nodes to the cluster
        free_nodes = session.get(f"{host}/api/v1/cluster/freenodes",
                                 headers=auth_headers).json()
        for fn in free_nodes:
            r = session.post(f"{host}/api/v1/cluster/main/nodes/{fn['uid']}",
                            headers=auth_headers, json={})
            if r.status_code in (200, 201):
                print(f"✅ Added nodes success! Status code: {r.status_code}")

        raise Exception("Not ready")


def _apply_manifest(session, host, auth_headers, path, skip_first=False):
    """PUT a YAML manifest to the cluster plugins endpoint and verify every
    document was applied (created or already present). Raises 'Not ready'
    otherwise so the caller can retry."""

    plugins_url = f"{host}/api/v1/cluster/main/plugins"

    with open(path, "rb") as f:
        files = {"file": (os.path.basename(path), f, "application/x-yaml")}
        resp = session.put(plugins_url, headers=auth_headers, files=files)
    if resp.status_code in (200, 201):
        print(f"✅ YAML apply success! Status code: {resp.status_code}")

    try:
        print(json.dumps(resp.json(), indent=2))

        # skip_first drops the namespace doc result (created, not "already exists")
        rows = resp.json()[1:] if skip_first else resp.json()
        for r in rows:
            if r["text"] != "Object already exists":
                raise Exception("Not ready")

    except Exception:
        print(resp.text)
        raise Exception("Not ready")


def mgx_mgmt_cluster_wait():

    while True:
        try:
            mgx_mgmt_cluster()
            return

        except Exception as e:
            print(f"mgx-mgmt-cluster failed: {e}")
            time.sleep(5)


def mgx_mgmt_cluster():

    # run only on first node
    if not is_first_node():
        return

    # Load pool info JSON
    with open(POOL_INFO_FILE, "r") as f:
        pool_info = json.load(f)

    nodes_count = pool_info.get("config", {}).get("nodes_count")

    session, host, auth_headers = _gw_session()

    # Form the mgmt cluster (mgx-core nodes)
    _ensure_cluster(session, host, auth_headers, nodes_count)

    # Apply the mgmt manifest: behavior config + downstream pool registry
    generate_mgmt_yaml()
    _apply_manifest(session, host, auth_headers, GEN_MANIFEST_FILE_MGMT,
                    skip_first=True)

    # if enable_grafana is False then return
    if is_grafana_enabled() is not True:
        return

    # put systemd manifest (grafana VIP service)
    _apply_manifest(session, host, auth_headers, MANIFEST_FILE_SRV)


def mgx_cluster_wait():

    while True:
        try:
            mgx_cluster()
            return

        except Exception as e:
            print(f"mgx-cluster failed: {e}")
            time.sleep(5)


def mgx_cluster():

    # run only on first node
    if not is_first_node():
        return

    # Load pool info JSON
    with open(POOL_INFO_FILE, "r") as f:
        pool_info = json.load(f)

    nodes_count = pool_info.get("config", {}).get("nodes_count")

    session, host, auth_headers = _gw_session()

    # Form the storage cluster (mgx-core nodes)
    _ensure_cluster(session, host, auth_headers, nodes_count)

    # Apply manifests: cache config/pool first (skip_first drops the namespace
    # doc result), then the storage/scheduler/snapshot config.
    generate_cache_yaml()
    _apply_manifest(session, host, auth_headers, GEN_MANIFEST_FILE, skip_first=True)
    _apply_manifest(session, host, auth_headers, GEN_MANIFEST_FILE_S)

    # if enable_grafana is False then return
    if is_grafana_enabled() is not True:
        return

    # put systemd manifest (grafana VIP service)
    _apply_manifest(session, host, auth_headers, MANIFEST_FILE_SRV)


if __name__ == "__main__":
        
    op = sys.argv[1]

    try:

        if op == "mgx-id":
            mgx_id()
        elif op == "mgx-hosts":
            mgx_hosts()
        elif op == "mgx-env":
            mgx_env()
        elif op == "mgx-spdk":
            mgx_spdk()
        elif op == "mgx-cass-seeds":
            mgx_cass_seeds()
        elif op == "mgx-cass-nodes-count":
            mgx_cass_nodes_count()
        elif op == "mgx-storage-vol-count":
            mgx_storage_vol_count()
        elif op == "mgx-cluster":
            mgx_cluster_wait()
        elif op == "mgx-mgmt-cluster":
            mgx_mgmt_cluster_wait()
        elif op == "is-metrics-enabled":
            is_metrics_enabled()
        elif op == "is-cross-peer-scrape":
            is_cross_peer_scrape()
        elif op == "prometheus-federate":
            prometheus_federate()
        elif op == "cache-type":
            cache_type()

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
