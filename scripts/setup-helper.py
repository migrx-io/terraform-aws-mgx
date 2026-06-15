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

    # generate default config for volumes
    rendered_s = template_s.format(**{
        "s3_bucket_name": values["s3_bucket"],
        "s3_backup_bucket": values["s3_backup_bucket"],
    })

    # Save next to cache.yaml
    with open(GEN_MANIFEST_FILE, "w") as f:
        f.write(rendered)

    with open(GEN_MANIFEST_FILE_S, "w") as f:
        f.write(rendered_s)


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

    merged_env = read_env_file(MERGED_ENV_FILE)

    pool_info = {}
    # Load pool info JSON
    with open(POOL_INFO_FILE, "r") as f:
        pool_info = json.load(f)

    host = "http://{}:{}".format(merged_env["CASS_RPC_ADDR"], merged_env["MGX_GW_PORT"])
    username = "admin"
    password = merged_env["MGX_GW_ADMIN_PASSWD"]

    session = requests.Session()
    headers = {"accept": "application/json", "Content-Type": "application/json"}

    # Step 1: Authenticate
    auth_url = f"{host}/api/v1/auth"
    auth_data = {
        "cluster": "main",
        "ns": "main",
        "username": username,
        "password": password,
    }

    resp = session.post(auth_url, headers=headers, json=auth_data)
    if resp.status_code != 200:
        print(f"❌ Auth failed! Status code: {resp.status_code}")
        raise Exception(resp.text)

    access_token = resp.json().get("access_token")
    if not access_token:
        print("❌ Failed to extract access_token")
        raise Exception("No found token")

    auth_headers = {"accept": "application/json", "Authorization": f"JWT {access_token}"}

    # Step 2: Get cluster list
    nodes_url = f"{host}/api/v1/cluster"
    resp = session.get(nodes_url, headers=auth_headers)
    if resp.status_code in (200, 201):
        print(f"✅ Get nodes success! Status code: {resp.status_code}")
    else:
        raise Exception(resp.text)

    if len(resp.json()) == 0:

        # Create cluster if not exist
        cluster_url = f"{host}/api/v1/cluster/main"
        cluster_data = {"node_ids": ["*"], "vip": "127.0.0.1"}
        resp = session.post(cluster_url, headers=auth_headers, json=cluster_data)
        if resp.status_code in (200, 201):
            print(f"✅ Cluster create success! Status code: {resp.status_code}")
        else:
            raise Exception(resp.text)

    # Step 3: Get cluster nodes
    nodes_url = f"{host}/api/v1/cluster/main/nodes"
    resp = session.get(nodes_url, headers=auth_headers)
    if resp.status_code in (200, 201):
        print(f"✅ Get nodes success! Status code: {resp.status_code}")
    else:
        raise Exception(resp.text)

    # check if nodes is connected
    if len(resp.json()) != pool_info.get("config", {}).get("nodes_count"):
        print("❌ Not enough nodes in main cluster {} != {}".format(len(resp.json()), 
                                                                    pool_info.get("config", {}).get("nodes_count")))

        # Get freenodes list
        nodes_url = f"{host}/api/v1/cluster/freenodes"
        resp = session.get(nodes_url, headers=auth_headers)
        free_nodes = resp.json()

        for fn in free_nodes:
            nodes_url = f"{host}/api/v1/cluster/main/nodes/{fn['uid']}"
            resp = session.post(nodes_url, headers=auth_headers, json={})
            if resp.status_code in (200, 201):
                print(f"✅ Added nodes success! Status code: {resp.status_code}")

        raise Exception("Not ready")

    # Step 4: Apply YAML
    # generate file
    generate_cache_yaml()

    plugins_url = f"{host}/api/v1/cluster/main/plugins"

    with open(GEN_MANIFEST_FILE, "rb") as f:
        files = {"file": (os.path.basename(GEN_MANIFEST_FILE), f, "application/x-yaml")}
        resp = session.put(plugins_url, headers=auth_headers, files=files)
    if resp.status_code in (200, 201):
        print(f"✅ YAML apply success! Status code: {resp.status_code}")

    try:
        print(json.dumps(resp.json(), indent=2))

        # check if resource applied
        # chekc namespace only
        for r in resp.json()[1:]:
            if r["text"] != "Object already exists":
                raise Exception("Not ready")


    except Exception:
        print(resp.text)
        raise Exception("Not ready")

    # put storage manifest
    with open(GEN_MANIFEST_FILE_S, "rb") as f:
        files = {"file": (os.path.basename(GEN_MANIFEST_FILE_S), f, "application/x-yaml")}
        resp = session.put(plugins_url, headers=auth_headers, files=files)
    if resp.status_code in (200, 201):
        print(f"✅ YAML apply success! Status code: {resp.status_code}")

    try:
        print(json.dumps(resp.json(), indent=2))

        # check if resource applied
        for r in resp.json():
            if r["text"] != "Object already exists":
                raise Exception("Not ready")

    except Exception:
        print(resp.text)
        raise Exception("Not ready")


    # if enable_grafana is False then return
    if is_grafana_enabled() is not True:
        return

    # put systemd manifest
    with open(MANIFEST_FILE_SRV, "rb") as f:
        files = {"file": (os.path.basename(MANIFEST_FILE_SRV), f, "application/x-yaml")}
        resp = session.put(plugins_url, headers=auth_headers, files=files)
    if resp.status_code in (200, 201):
        print(f"✅ YAML apply success! Status code: {resp.status_code}")

    try:
        print(json.dumps(resp.json(), indent=2))

        # check if resource applied
        for r in resp.json():
            if r["text"] != "Object already exists":
                raise Exception("Not ready")

    except Exception:
        print(resp.text)
        raise Exception("Not ready")


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
        elif op == "is-metrics-enabled":
            is_metrics_enabled()
        elif op == "cache-type":
            cache_type()

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
