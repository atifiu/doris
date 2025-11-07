#!/bin/bash
# Commands used for building and testing Doris with case-sensitivity fixes

# Install basic build dependencies
sudo apt-get update
sudo apt-get install -y build-essential flex

# Install JDK 17 and set JAVA_HOME
sudo apt-get install -y openjdk-17-jdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export JDK_17=/usr/lib/jvm/java-17-openjdk-amd64

# Ensure protoc is available where gensrc expects it
# Faster path: use system protobuf-compiler and symlink to thirdparty/installed/bin/protoc
sudo apt-get install -y protobuf-compiler
mkdir -p /workspaces/doris/thirdparty/installed/bin
if [ ! -x /workspaces/doris/thirdparty/installed/bin/protoc ]; then
	ln -sf /usr/bin/protoc /workspaces/doris/thirdparty/installed/bin/protoc
fi

# Ensure thrift is available where gensrc expects it
sudo apt-get install -y thrift-compiler
if [ ! -x /workspaces/doris/thirdparty/installed/bin/thrift ]; then
	ln -sf /usr/bin/thrift /workspaces/doris/thirdparty/installed/bin/thrift
fi

# Optional: build full thirdparty toolchain if needed (takes longer)
# pushd /workspaces/doris/thirdparty
# ./build-thirdparty.sh
# popd

# Run frontend unit tests
./run-fe-ut.sh

# Note: If you only need to run specific tests, you can use:
# mvn test -pl fe/fe-core -Dtest=UtilTest,ShowTableStatusCommandTest

###############################################
# Build full Doris (FE + BE) and run locally  #
###############################################

# Download thirdparty prebuilt archives (faster than building from source)
pushd /workspaces/doris/thirdparty
bash download-thirdparty.sh
popd

# Build FE and BE (adjust -j to your CPU cores)
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export JDK_17=/usr/lib/jvm/java-17-openjdk-amd64
bash build.sh --fe --be -j2

# Prepare runtime directories
mkdir -p /workspaces/doris/doris-meta
mkdir -p /workspaces/doris/storage

# Start FE and BE
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export JDK_17=/usr/lib/jvm/java-17-openjdk-amd64
bin/start_fe.sh --daemon

# Some environments can't change vm.max_map_count; skip those checks for BE
export SKIP_CHECK_ULIMIT=true
bin/start_be.sh --daemon

# Install MySQL client for manual checks (optional if already installed)
sudo apt-get update && sudo apt-get install -y mysql-client

# Add BE to FE and verify
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '127.0.0.1:9050';"
mysql -h 127.0.0.1 -P9030 -uroot -e "SHOW BACKENDS;"

###############################################
# Manual verification of the temp-table fix   #
###############################################

# 1) Create DB and temp table
mysql -h 127.0.0.1 -P9030 -uroot -e "\
DROP DATABASE IF EXISTS test_temp_fix; \
CREATE DATABASE test_temp_fix; \
USE test_temp_fix; \
CREATE TEMPORARY TABLE t1 (id INT, name VARCHAR(50)) \
DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES('replication_num'='1'); \
INSERT INTO t1 VALUES (1,'Alice'),(2,'Bob'); \
SHOW TABLES; \
SHOW TABLE STATUS; \
SELECT * FROM t1 ORDER BY id; \
"

# 2) Ensure SHOW TABLES/STATUS do not expose internal temp sign
# (manually check that names do not contain "__doris_temp__" in any case)

###############################################
# Run the single regression test we added     #
###############################################

# The regression harness expects a running local FE/BE on 127.0.0.1
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
./run-regression-test.sh --run -f regression-test/suites/temp_table_p0/test_temp_table_case_sensitivity.groovy