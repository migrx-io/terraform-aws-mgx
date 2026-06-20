#!/bin/bash

# Cassandra cluster configuration, auth bootstrap and schema migration. Run this
# on the actual setup, after mgx-cassandra-install-deb.sh has installed the
# packages. Requires these env vars (exported by setup-node.sh):
#   CASS_RPC_ADDR     this node's address
#   CASS_RPC_SEEDS    comma-separated seed list (host:port)
#   CASS_NODES_COUNT  expected number of nodes (wait target)
#   CASS_USER         superuser to create
#   CASS_PASSWD       superuser password
#   PYENV             path to the pyenv bin dir holding cassandra-migrate

echo " Cassandra Cluster Setup"
echo ""

# Retry a command on transient cluster errors. cqlsh / cassandra-migrate use the
# Python driver and fail with "Connection error: ('Unable to connect to any
# servers', [...])" while gossip is still settling or a peer is briefly
# unreachable. setup-node.sh runs this script under `bash -e`, so without a retry
# a single blip aborts the whole provisioning run. Every wrapped statement is
# idempotent (CREATE ... IF NOT EXISTS, ALTER, DROP IF EXISTS, migrate), so it is
# safe to run again.
retry() {
    local n=0 max=60 delay=5
    until "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$max" ]; then
            echo "❌ Command still failing after ${max} attempts: $*" >&2
            return 1
        fi
        echo "Attempt ${n}/${max} failed, retrying in ${delay}s: $*"
        sleep "$delay"
    done
}

echo "STEP 1. Clear data.."
echo ""

systemctl stop cassandra

# clear data if exists
rm -rf /var/lib/cassandra/commitlog/*
rm -rf /var/lib/cassandra/hints/*
rm -rf /var/lib/cassandra/saved_caches/*

CURRENT_CLUSTER=$(grep -E '^cluster_name:' /etc/cassandra/cassandra.yaml | awk -F': ' '{print $2}' | tr -d '"')
if [ "$CURRENT_CLUSTER" != "Migrx" ]; then
    rm -rf /var/lib/cassandra/data/*
    FRESH_BOOTSTRAP=1
else
    FRESH_BOOTSTRAP=0
fi

echo "STEP 2. Configurate.."
echo ""

# set cluster name
sed -i "s/cluster_name:.*/cluster_name: Migrx/g" /etc/cassandra/cassandra.yaml

# set snitch type
sed -i "s/endpoint_snitch:.*/endpoint_snitch: GossipingPropertyFileSnitch/g" /etc/cassandra/cassandra.yaml

# set authtorizer
sed -i "s/authenticator:.*/authenticator: PasswordAuthenticator/g" /etc/cassandra/cassandra.yaml


# set addr
sed -i "s/listen_address:.*/listen_address: ${CASS_RPC_ADDR}/g" /etc/cassandra/cassandra.yaml
sed -i "s/rpc_address:.*/rpc_address: ${CASS_RPC_ADDR}/g" /etc/cassandra/cassandra.yaml
sed -i "s/127.0.0.1:7000/${CASS_RPC_ADDR}:7000/g" /etc/cassandra/cassandra.yaml
sed -i "s/127.0.0.1:7000/${CASS_RPC_ADDR}:7000/g" /etc/cassandra/cassandra.yaml

# CASS_RPC_SEEDS is the full node list (also used for metrics scrape targets and
# the stagger index below). Cassandra itself should only seed off the first two
# nodes: making every node a seed means no node auto-bootstraps and several
# seeds starting at once can split gossip, leaving a node invisible cluster-wide.
CASS_SEEDS=$(echo "${CASS_RPC_SEEDS}" | cut -d',' -f1-2)
sed -i "s/^\(\s*-\s*seeds:\s*\).*/\1\"${CASS_SEEDS}\"/" /etc/cassandra/cassandra.yaml

FIRST_SEED=$(echo "${CASS_RPC_SEEDS}" | cut -d',' -f1)
FIRST_SEED_IP="${FIRST_SEED%%:*}"
TARGET=${CASS_NODES_COUNT}

# This node's 0-based position in the full node list, used to stagger fresh
# joins so nodes don't bootstrap simultaneously.
MY_INDEX=$(echo "${CASS_RPC_SEEDS}" | tr ',' '\n' | sed 's/:.*//' | grep -nxF "${CASS_RPC_ADDR}" | head -1 | cut -d: -f1)
MY_INDEX=$((MY_INDEX - 1))

# The default 'cassandra' superuser is auto-created the first time a node starts
# with PasswordAuthenticator. If several nodes do that at once (system_auth is
# SimpleStrategy RF=1 at bootstrap) the inserts race and can leave a row with a
# null can_login/is_superuser -> "Invalid metadata for role cassandra" NPE at
# the very first login. Start the first seed alone; every other node waits until
# the first seed has finished its auth bootstrap before it boots and joins.
#
# This staggering only applies to a FRESH cluster. On a re-provision the
# default 'cassandra' login no longer works (its password was changed) and
# system_auth is NetworkTopologyStrategy RF=3, so authenticating as CASS_USER
# can't reach quorum while only the first seed is up. Waiting here would
# deadlock: non-seeds won't start until the seed is "ready", the seed won't
# see enough nodes until the non-seeds start. So skip the wait on re-provision
# and let every node start immediately and re-form quorum.
if [ "${CASS_RPC_ADDR}" != "${FIRST_SEED_IP}" ] && [ "${FRESH_BOOTSTRAP}" = "1" ]; then
    echo "Not first seed — waiting for first seed ${FIRST_SEED_IP} to finish auth bootstrap..."
    until cqlsh -u cassandra -p cassandra ${FIRST_SEED_IP} -e "SHOW HOST" >/dev/null 2>&1 \
       || cqlsh -u "${CASS_USER}" -p "${CASS_PASSWD}" ${FIRST_SEED_IP} -e "SHOW HOST" >/dev/null 2>&1; do
        echo "First seed auth not ready yet, waiting..."
        sleep 5
    done

    # Stagger joins so nodes don't bootstrap at the same instant (which can split
    # gossip). Instead of a fixed sleep, join only once the previous node has
    # fully joined. A node at 0-based MY_INDEX should start once nodes
    # 0..MY_INDEX-1 are up — i.e. once the cluster reports >= MY_INDEX UP nodes.
    # nodetool status counts all UP (UN) nodes including the seed itself, so this
    # waits for real join completion of the previous node, not a guessed delay.
    echo "Waiting until node(s) are up before starting (node index ${MY_INDEX})..."
    while true; do
        cnt=$(nodetool status | grep '^UN' | wc -l)
        if [ "$cnt" -ge "${MY_INDEX}" ]; then
            echo "$cnt node(s) up (need ${MY_INDEX}) — starting."
            break
        fi
        echo "Only $cnt node(s) up (need ${MY_INDEX}), waiting..."
        sleep 5
    done
fi

systemctl enable cassandra
systemctl restart cassandra

# wait while it up
echo "Waiting for Cassandra to be ready on port 9042..."
until nc -z ${CASS_RPC_ADDR} 9042; do
    sleep 2
done

# wait all nodes is up before run
while true; do
    cnt=$(nodetool status | grep '^UN' | wc -l)
    if [ "$cnt" -ge "$TARGET" ]; then
        echo "✅ $cnt nodes are up."
        break
    else
        echo "Currently $cnt nodes up. Waiting..."
        sleep 5
    fi
done


if [ "${CASS_RPC_ADDR}" = "${FIRST_SEED_IP}" ]; then


    if cqlsh -u "${CASS_USER}" -p "${CASS_PASSWD}" ${CASS_RPC_ADDR} -e "SHOW HOST" >/dev/null 2>&1; then
    	echo "User ${CASS_USER} already works, skipping bootstrap."
    else

	    echo "Waiting for Cassandra to accept auth..."
	    until cqlsh -u cassandra -p cassandra ${CASS_RPC_ADDR} -e "SHOW HOST" >/dev/null 2>&1; do
		sleep 5
	    done

	    retry cqlsh -u cassandra -p cassandra ${CASS_RPC_ADDR} -e  "ALTER KEYSPACE \"system_auth\" WITH REPLICATION = {'class' : 'NetworkTopologyStrategy', 'dc1' : 3};"

	    retry cqlsh -u cassandra -p cassandra ${CASS_RPC_ADDR} -e "CREATE ROLE IF NOT EXISTS ${CASS_USER} WITH PASSWORD = '${CASS_PASSWD}' AND SUPERUSER = true AND LOGIN = true;"

	    retry cqlsh -u ${CASS_USER} -p ${CASS_PASSWD} ${CASS_RPC_ADDR} -e "ALTER ROLE cassandra WITH PASSWORD='${CASS_PASSWD}' AND SUPERUSER=false;"

        # install schema
        cd /opt/mgx-schema
        retry cqlsh -u ${CASS_USER} -p ${CASS_PASSWD} ${CASS_RPC_ADDR} -e 'DROP KEYSPACE IF EXISTS dc1;'
        retry ${PYENV}/cassandra-migrate -y -m prod -c dc1.yaml -u ${CASS_USER} -P ${CASS_PASSWD} -H ${CASS_RPC_ADDR} migrate
        cd -

    fi

else
    echo "This is not the first seed (${CASS_RPC_ADDR}), skipping auth + replication setup."
fi
