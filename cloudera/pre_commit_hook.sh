#!/bin/bash
set -ex

#Setup environment vars for build
export JAVA8_BUILD=true
. /opt/toolchain/toolchain.sh
export PATH="$MAVEN_3_5_0_HOME/bin:$PATH"
export ANT_OPTS="-XX:PermSize=256m"
export BRANCH_NAME="cdh6.x"
# get a GBN to build against for other project dependencies
export CDH_GBN="$(curl "http://builddb.infra.cloudera.com:8080/resolvealias?alias=${BRANCH_NAME}")"

/usr/bin/env

# not sure why, but ant and mvn aren't on the path even after sourcing toolchain above...
export PATH="$PATH:/opt/toolchain/apache-ant-1.8.2/bin:/opt/toolchain/apache-maven-3.0.4/bin"

# Ensure our maven settings file points at the GBN we got above
curl -L http://github.mtv.cloudera.com/raw/CDH/cdh/${BRANCH_NAME}/gbn-m2-settings.xml > mvn_settings.xml
mvn -s mvn_settings.xml -f cloudera-pom.xml process-resources -U -B

#Test Pig
ant clean jar test-commit -Dhadoopversion=3 -Dtest.junit.output.format=xml

