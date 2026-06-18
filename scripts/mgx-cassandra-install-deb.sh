#!/bin/bash

# Cassandra package install only. No env vars required, so this can be run
# standalone to bake an image. Cluster configuration, auth bootstrap and schema
# migration live in mgx-cassandra-cluster-deb.sh and run on the actual setup.

echo " Cassandra Installer"
echo ""

echo "STEP 1. Install packages.."
echo ""

curl -o /etc/apt/keyrings/apache-cassandra.asc https://downloads.apache.org/cassandra/KEYS
echo "deb [signed-by=/etc/apt/keyrings/apache-cassandra.asc] https://debian.cassandra.apache.org 41x main" | tee /etc/apt/sources.list.d/cassandra.sources.list
apt-get update
apt install -y cassandra

echo "Cassandra packages installed. Run mgx-cassandra-cluster-deb.sh to configure the cluster."
