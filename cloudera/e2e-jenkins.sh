#!/usr/bin/env bash
# (c) Copyright 2015 Cloudera, Inc.

# Some defaults.
PIG_GIT_REPO="git://github.mtv.cloudera.com/nkollar/pig.git"

DEFAULT_CLOUDCAT_USERNAME="nkollar"

DEFAULT_CLOUD_COMPONENT="CDH-Nightly"
DEFAULT_CLOUD_MASTER_SIZE="xlargemem"
DEFAULT_CLOUD_SLAVE_SIZE="extralarge"

# Keeping the cluster for 12 hours only if we don't want to preserve it anyway
# so if we somehow don't run destroy, the instances will only run CLOUD_EXPIRATION_HOURS
# hours instead of 24 hours (which is the default of Cloudcat).
DEFAULT_CLOUD_EXPIRATION_HOURS="12"

# Commands run against TEST_EXECUTION_HOST are done over SSH. Set defaults for these calls to
# disable strict host key checking and not to write to a known hosts file to avoid common
# automation pitfalls. Also, we add -q to suppress diagnostic and warning messages that we don't
# care about.
DEFAULT_TEST_EXECUTION_HOST_SSH_ARGUMENTS=(-o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no -q)
# jenkins is the default TEST_EXECUTION_HOST user since the user on Jenkins slaves tends to be
# Jenkins.
DEFAULT_TEST_EXECUTION_HOST_SSH_USER="jenkins"

# Location where smokes source is stored
PIG_HOME=${WORKSPACE-$(realpath $(dirname "${BASH_SOURCE[0]}")/..)}

# With Cauldron builds, we can specify a bquery wich will resolve into GBN.
# For ex, bquery://product=cdh:version=6.x:Redhat7_repo.
# See readme section of http://github.mtv.cloudera.com/CDH/cdh/tree/cdh6.x, for more details.
resolveCDH() {
  echo Resolving CDH GBN: ../target/env/bin/resjson resolve "${CDH}"
  local GBN=$(sudo docker run --net=host "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
      ../target/env/bin/resjson resolve "${CDH}")

  echo CDH_GBN=${GBN}

  if [ -z "${GBN}" ]; then
    printCenteredText "Failed to resolve CDH_GBN. Exiting..." >&2
    return 1
  fi

  export CDH_GBN=${GBN}
}

resolveCM() {
  echo Resolving CM GBN: ../target/env/bin/resjson resolve "${CM}"
  local GBN=$(sudo docker run --net=host "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
      ../target/env/bin/resjson resolve "${CM}")

  echo CM_GBN=${GBN}

  if [ -z "${GBN}" ]; then
    printCenteredText "Failed to resolve CM_GBN. Exiting..." >&2
    return 1
  fi

  export CM_GBN=${GBN}
}

# Simple utility function to print banners of left-justified text.
printFlushLeftText() {
  TEXT="${1}"
  LINE_WIDTH="${2:-100}"
  LINE_WIDTH_AVAILABLE=$((${LINE_WIDTH} - 2))
  SPACE_AFTER=$((${LINE_WIDTH_AVAILABLE} - ${#TEXT} - 1))
  SPACE_BEFORE=$((${LINE_WIDTH_AVAILABLE} - ${#TEXT} - ${SPACE_AFTER}))

  printf "%${LINE_WIDTH}s\n" | tr ' ' '*'
  printf "*%${SPACE_BEFORE}s${TEXT}%${SPACE_AFTER}s*\n" " " " "
  printf "%${LINE_WIDTH}s\n" | tr ' ' '*'
}

# Simple utility function to print banners of centered text.
printCenteredText() {
  TEXT="${1}"
  LINE_WIDTH="${2:-100}"
  LINE_WIDTH_AVAILABLE=$((${LINE_WIDTH} - 2))
  SPACE_AFTER=$(((${LINE_WIDTH_AVAILABLE} - ${#TEXT})/ 2))
  SPACE_BEFORE=$((${LINE_WIDTH_AVAILABLE} - ${#TEXT} - ${SPACE_AFTER}))

  printf "%${LINE_WIDTH}s\n" | tr ' ' '*'
  printf "*%${SPACE_BEFORE}s${TEXT}%${SPACE_AFTER}s*\n" " " " "
  printf "%${LINE_WIDTH}s\n" | tr ' ' '*'
}

# Basic validation that the Jenkins parameters expected to be set are set.
validateParameters() {
  local NODE_TYPE="${1}"
  for parameter in CDH \
      CM \
      OS \
      CONFIG \
      PIG_BRANCH \
      RELEASE \
      CDEP_DOCKER_IMAGE_TAG \
      KEEP_CLUSTERS_ONLINE \
      ALWAYS_COLLECT_DIAGNOSTIC_BUNDLES; do
    if [ -z "${!parameter}" ]; then
      PARAMETERS_MISSING+=("${parameter}")
    fi
  done

  if [ "${#PARAMETERS_MISSING[@]}" -gt 0 ]; then
    printFlushLeftText "The following required parameters are not set:" >&2
    for parameter in "${PARAMETERS_MISSING[@]}"; do
      echo "- ${parameter}" >&2
    done
    printCenteredText "Missing required parameters. Exiting..." >&2
    exit 1
  fi
  if [ "${NODE_TYPE}" = "preexisting_machines" ] && [ -z "${HOSTS}" ]; then
    printCenteredText "Missing HOSTS parameter. Exiting..." >&2
    exit 1
  fi
}

# Takes in two arguments: either 'cloud' or 'docker' for the way hosts will be provisioned,
# and the number of hosts.
createHostnames() {
  local NODE_TYPE="${1}"
  local NUMBER_OF_MACHINES="${2}"
  if [ "${NODE_TYPE}" = "docker" ]; then
    HOSTS="node-{1.."${NUMBER_OF_MACHINES}"}.network${RANDOM_STRING}"
  elif [ "${NODE_TYPE}" = "cloud" ]; then
    case "${OS}" in
      CentOS6.4|CentOS6.6|CentOS6.7|CentOS6.8|CentOS7.1|RedHat6.7|SLES11SP4|SLES11SP3|Oracle6.4|Debian7.8|Debian8.1|Debian8.4|Ubuntu12.04)
        CLOUD="GCE" ;;
      *)
        CLOUD="EC2" ;;
    esac

    # Trim periods and make all characters in OS lowercase.
    OS=$(tr -d . <<< $(tr [:upper:] [:lower:] <<< ${OS}))

    # Create the hostnames.
    HOSTS="cdh${RELEASE//./-}-${OS}-${RANDOM_STRING}-"
    if [ "${CLOUD}" = "GCE" ]; then
      HOSTS+="{1.."${NUMBER_OF_MACHINES}"}.gce.cloudera.com"
    elif [ "${CLOUD}" = "EC2" ]; then
      HOSTS+="{1.."${NUMBER_OF_MACHINES}"}.vpc.cloudera.com"
    elif [ "${CLOUD}" = "AZURE" ]; then
      # TODO: not sure about hostnames for Azure
      HOSTS+="{mn0,dn0,dn1,dn2}.azure.cloudera.com"
    fi
  fi
}

# Takes in two arguments: either 'cloud' or 'docker' for the way hosts should be provisioned,
# and the number of hosts.
provisionHosts() {
  local NODE_TYPE="${1}"
  local NUMBER_OF_MACHINES="${2}"
  if [ "${NODE_TYPE}" = "cloud" ]; then
    printCenteredText "Beginning host provisioning..."

    CLOUD_PROVISIONING_ARGS+=(--hosts="${HOSTS}")
    CLOUD_PROVISIONING_ARGS+=(--os="${OS}")
    CLOUD_PROVISIONING_ARGS+=(--cloud-type="${CLOUD}")
    CLOUD_PROVISIONING_ARGS+=(--component="${CLOUD_COMPONENT:-${DEFAULT_CLOUD_COMPONENT}}")
    CLOUD_PROVISIONING_ARGS+=(--master-size="${CLOUD_MASTER_SIZE:-${DEFAULT_CLOUD_MASTER_SIZE}}")
    CLOUD_PROVISIONING_ARGS+=(--slave-size="${CLOUD_SLAVE_SIZE:-${DEFAULT_CLOUD_SLAVE_SIZE}}")

    if [ "${KEEP_CLUSTERS_ONLINE}" != "true" ]; then
      CLOUD_PROVISIONING_ARGS+=(--expiration-days=0)
      ACTUAL_EXPIRATION_HOURS="${CLOUD_EXPIRATION_HOURS:-${DEFAULT_CLOUD_EXPIRATION_HOURS}}"
      CLOUD_PROVISIONING_ARGS+=(--expiration-hours="${ACTUAL_EXPIRATION_HOURS}")
    fi

    if [ "${CLOUD}" = "AZURE" ]; then
      DEFAULT_AZURE_SUBSCRIPTION_ID="75f8b032-1483-4fe1-85db-e492b059a6fa"
      DEFAULT_AZURE_ACTIVE_DIRECTORY="adcloudera.onMicrosoft.com"
      DEFAULT_AZURE_CLIENT_ID="353d1c51-6ef4-4779-8cdd-f15ea63f566b"
      DEFAULT_AZURE_CLIENT_SECRET="YNwz10Z7fKcLpbkhucqMub36aKXAnRsfSPc75iyhvkg="

      CLOUD_PROVISIONING_ARGS+=(--azure-subscription-id="${AZURE_SUBSCRIPTION_ID:-${DEFAULT_AZURE_SUBSCRIPTION_ID}}")
      CLOUD_PROVISIONING_ARGS+=(--azure-active-directory-name="${AZURE_ACTIVE_DIRECTORY:-${DEFAULT_AZURE_ACTIVE_DIRECTORY}}")
      CLOUD_PROVISIONING_ARGS+=(--azure-client-id="${AZURE_CLIENT_ID:-${DEFAULT_AZURE_CLIENT_ID}}")
      CLOUD_PROVISIONING_ARGS+=(--azure-client-secret="${AZURE_CLIENT_SECRET:-${DEFAULT_AZURE_CLIENT_SECRET}}")

      # Right now Azure functionality is still being implemented, meaning it may be flaky or
      # missing functionality. To set the right expectations in the interim, we are requiring
      # this flag.
      CLOUD_PROVISIONING_ARGS+=(--enable-beta-features)

    else
      # Generate CloudCat-specific arguments to pass to cloud_provisioner.py.
      CLOUD_PROVISIONING_ARGS+=(--username="${CLOUDCAT_USERNAME:-${DEFAULT_CLOUDCAT_USERNAME}}")
    fi

    # Invoke cloud_provisioner.py's create_group argument as well as suppress_provisioned_email and
    # suppress_expiration_email to cut down on spam. The --net=host option tells Docker to make
    # the host's network stack available within the cdep container. This is needed to ensure that
    # cdep can reach all nodes accessible from the host. We also pass in environmental variables
    # to facilitate usage tracking (see KITCHEN-13253).
    if sudo docker run --net=host -v "${WORKSPACE}"/target:/root/deploy/cdep/target \
        -e "JOB_NAME=${JOB_NAME}" -e "BUILD_NUMBER=${BUILD_NUMBER}" \
        -v /etc/localtime:/etc/localtime "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
        ./infrastructure/cloud_provisioner.py "${CLOUD_PROVISIONING_ARGS[@]}" create_group \
        suppress_provisioned_email suppress_expiration_email; then
      printCenteredText "Host provisioning succeeded."
    else
      printCenteredText "Host provisioning failed. Exiting..." >&2
      return 1
    fi
  elif [ "${NODE_TYPE}" = "docker" ]; then
    if clusterdock_run ./bin/start_cluster --always-pull -o "${OS}" -n "network${RANDOM_STRING}" \
        systest_nodebase --nodes="node-{1.."${NUMBER_OF_MACHINES}"}"; then
      printCenteredText "Docker container cluster creation succeeded."
    else
      printCenteredText "Docker container cluster creation failed. Exiting..." >&2
      return 1
    fi
  else
    printCenteredText "Wrong NODE_TYPE argument passed - host provisioning failed. Exiting..." >&2
    return 1
  fi
  return 0
}


deployCluster() {
  local NODE_TYPE="${1}"
  printCenteredText "Beginning cluster deployment..."

  cat << __EOF
 Once the Cloudera Manager server is installed, you can follow along at
 http://${CM_MASTER_HOST}:7180.
__EOF

  # Generate CDEP_ARGS by parsing CONFIG.
  read PACKAGING SECURITY DB HA JAVA_VERSION CONFIG_SPECIFIC_CDEP_ARGS <<< ${CONFIG}

  if [ "${PACKAGING}" = "parcels" ]; then
    PACKAGING="+parcels"
  else
    PACKAGING=""
  fi

  # For Security, check for Kerberos, SSL, KMS seperately in the passed string
  case "${SECURITY}" in
    *kerberos-mit*)
      CDEP_ARGS+=(--use-kerberos) ;;
    *kerberos-ad*)
      CDEP_ARGS+=(--use-kerberos --use-ad-kdc) ;;
  esac

  case "${SECURITY}" in
    *ssl*)
      CDEP_ARGS+=(--enable-cdh-ssl) ;;
  esac

  case "${SECURITY}" in
    *file-kms*)
      CDEP_ARGS+=(--enable-kms) ;;
    *kt-kms*)
      CDEP_ARGS+=(--enable-keytrustee) ;;
  esac

  CDEP_ARGS+=(--database "${DB}")

  case "${HA}" in
    "ha"|"HA")
      CDEP_ARGS+=(--ha-service-types=ALL) ;;
  esac

  # To make our CONFIG more readable, we specify JDK versions with "java" prepended (e.g.
  # "java8" instead of just "8").
  CDEP_ARGS+=(--java=${JAVA_VERSION#java})

  # Add any other optional arguments, if they're passed.
  if [ -n "${OPTIONAL_CDEP_ARGS}" ]; then
    CDEP_ARGS+=(${OPTIONAL_CDEP_ARGS})
  fi

  # Add config specific cdep arguments, if they're passed.
  if [ -n "${CONFIG_SPECIFIC_CDEP_ARGS}" ]; then
    CDEP_ARGS+=(${CONFIG_SPECIFIC_CDEP_ARGS})
  fi

  # Add clean cdep action if NODE_TYPE is preexisting_machines
  if [ "${NODE_TYPE}" = "preexisting_machines" ]; then
    CDEP_ARGS+=(clean setup)
  else
    CDEP_ARGS+=(setup)
  fi

  echo "Running cdep command: ./sysadmin.py --agents gbn://${CDH_GBN}${PACKAGING}@${HOSTS} \
      --version gbn://${CM_GBN}" --no-locks "${CDEP_ARGS[@]} setup"
  if sudo docker run --net=host -v "${WORKSPACE}"/target:/root/deploy/cdep/target \
      -v /etc/localtime:/etc/localtime "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
      ./sysadmin.py --agents "gbn://${CDH_GBN}${PACKAGING}"@"${HOSTS}" \
      --version "gbn://${CM_GBN}" --no-locks "${CDEP_ARGS[@]}"; then
    printCenteredText "Cluster deployment succeeded."
  else
    printCenteredText "Cluster deployment failed. Exiting..." >&2
    return 1
  fi
}

collectDiagnosticBundles() {
  printCenteredText "Collecting diagnostic bundles..."

  if sudo docker run --net=host -v "${WORKSPACE}"/target:/root/output \
      -v /etc/localtime:/etc/localtime "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
      ./sysadmin.py --agents "gbn://${CDH_GBN}"@"${HOSTS}"  --version "gbn://${CM_GBN}" \
      -diagd /root/output collect_support_bundles; then
    printCenteredText "Diagnostic bundle collection succeeded."
  else
    printCenteredText "Diagnostic bundle collection failed. Will try to collect host logs..." >&2
    sudo docker run --net=host -v "${WORKSPACE}"/target:/root/deploy/cdep/target \
        -v /etc/localtime:/etc/localtime "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
        ./sysadmin.py --agents "gbn://${CDH_GBN}"@"${HOSTS}" --version "gbn://${CM_GBN}" \
        --no-locks download_debugging_files
  fi
}

setupClusterTestEnvironment() {
  # We setup the test environment over SSH on the TEST_EXECUTION_HOST. To help us determine what
  # happens if something goes wrong, we return different exit codes from the SSH command and then
  # display the matching error message later. Note that, in general, if any of the steps in the setup
  # process fail, we fail fast.
  printCenteredText "Setting up cluster test environment..."
  TEST_RUNNING_HOST="${1}"
  PIG_FOLDER_NAME="${2}"

  # Need to set up java for mvn.
  read PACKAGING SECURITY DB HA JAVA_VERSION <<< ${CONFIG}
  echo "Running cdep command: ./java.py --agents=gbn://${CDH_GBN}@${HOSTS}
      --version=gbn://${CM_GBN} --java="${JAVA_VERSION#java}" --no-locks setup link_default"
  if sudo docker run --net=host -v "${WORKSPACE}"/target:/root/deploy/cdep/target \
      -v /etc/localtime:/etc/localtime "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
      ./java.py --agents="gbn://${CDH_GBN}"@"${HOSTS}" --version="gbn://${CM_GBN}" \
      --java="${JAVA_VERSION#java}" --no-locks setup link_default; then
    printCenteredText "Java setup succeeded."
  else
    printCenteredText "Java setup failed. Continuing anyway..." >&2
  fi

  echo "Test execution host is: ${TEST_RUNNING_HOST}"
  echo "Test folder is: ${PIG_FOLDER_NAME}"
  SSH_USER="${TEST_EXECUTION_HOST_SSH_USER:-${DEFAULT_TEST_EXECUTION_HOST_SSH_USER}}"
  ssh ${TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]:-${DEFAULT_TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]}} \
      "${SSH_USER}@${TEST_RUNNING_HOST}" << __EOF
    sudo su - systest;

    # Set up Maven in /opt/toolchain and symlink it in /usr/bin to allow invocation via "mvn" alone.
    wget http://util-1.ent.cloudera.com/maven-3.3.3-bin.tar.gz && \
        sudo mkdir -p /opt/toolchain && \
        sudo tar zxf maven-3.3.3-bin.tar.gz -C /opt/toolchain && \
        sudo ln -f -s /opt/toolchain/apache-maven-3.3.3/bin/mvn /usr/bin/mvn && \
        rm -f maven-3.3.3-bin.tar.gz

    # Set up Ant
    wget http://xenia.sote.hu/ftp/mirrors/www.apache.org//ant/binaries/apache-ant-1.9.8-bin.tar.gz && \
       sudo mkdir -p /opt/toolchain && \
       sudo tar zxf apache-ant-1.9.8-bin.tar.gz -C /opt/toolchain && \
       sudo ln -f -s /opt/toolchain/apache-ant-1.9.8/bin/ant /usr/bin/ant && \
       rm -f maven-3.3.3-bin.tar.gz

    # Install required Perl modules
    sudo yum -y install perl-Parallel-ForkManager || sudo apt-get -y install libparallel-forkmanager-perl
    sudo yum -y install perl-IPC-Run || sudo apt-get -y install libipc-run-perl
    sudo yum -y install libdbi || sudo apt-get -y install libdbi-perl
__EOF

  case $? in
    0)
    printCenteredText "Cluster test environment setup succeeded." ;;
    3)
    printCenteredText "Maven installation failed. Exiting..." >&2
    return 3 ;;
    4)
    printCenteredText "git clone of QE/smokes failed. Exiting..." >&2
    return 4 ;;
    255)
    printCenteredText "Could not connect to ${CM_MASTER_HOST}. Exiting..." >&2
    return 255 ;;
    *)
    printCenteredText "Cluster test environment setup failed. Exiting..." >&2
    return 1 ;;
  esac
}

executeTests() {
  printCenteredText "Executing tests..."
  TEST_RUNNING_HOST="${1}"
  CM_MASTER="${2}"
  ADDITIONAL_ARGS="${3}"
  PIG_FOLDER_NAME="${4}"
  PIG_DESTINATION=/var/tmp/"${PIG_FOLDER_NAME}"

  echo "Test execution host is: ${TEST_RUNNING_HOST}"
  echo "CM Master node is: ${CM_MASTER}"
  echo "List of modules: ${ADDITIONAL_ARGS}"
  echo "Folder name: ${PIG_FOLDER_NAME}"
  echo  Destination folder is ${PIG_DESTINATION}

  # Run Maven in batch mode to prevent interactive output like downloading progress bars.
  E2E_TEST_DEPLOY_STRING=(ant \
      -buildfile ${PIG_DESTINATION}/build.xml \
      -Dhadoopversion=23 \
      -Dharness.old.pig=/usr \
      -Dharness.cluster.conf=/etc/hadoop/conf \
      -Dharness.cluster.bin=/bin/hadoop \
      -Dharness.hadoop.home=/opt/cloudera/parcels/CDH/lib/hadoop \
      test-e2e-deploy)
  E2E_TEST_EXECUTE_STRING=(ant \
      -buildfile ${PIG_DESTINATION}/build.xml \
      -Dhadoopversion=23 \
      -Dharness.old.pig=/usr \
      -Dharness.cluster.conf=/etc/hadoop/conf \
      -Dharness.cluster.bin=/bin/hadoop \
      -Dharness.hadoop.home=/opt/cloudera/parcels/CDH/lib/hadoop \
      test-e2e)

  echo "deploy command is ${E2E_TEST_DEPLOY_STRING[*]}"
  echo "execute command is ${E2E_TEST_EXECUTE_STRING[*]}"

  SSH_USER="${TEST_EXECUTION_HOST_SSH_USER:-${DEFAULT_TEST_EXECUTION_HOST_SSH_USER}}"
  scp ${TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]:-${DEFAULT_TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]}} \
      -r "${PIG_HOME}" "${SSH_USER}@${TEST_RUNNING_HOST}":"${PIG_DESTINATION}"

  ssh ${TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]:-${DEFAULT_TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]}} \
      "${SSH_USER}@${TEST_RUNNING_HOST}" << __EOF

    sudo su - hdfs
    hadoop fs -mkdir -p /user/systest
    hadoop fs -chown systest /user/systest
    hadoop fs -mkdir -p /user/pig
    hadoop fs -chown systest /user/pig
__EOF

  ssh ${TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]:-${DEFAULT_TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]}} \
      "${SSH_USER}@${TEST_RUNNING_HOST}" << __EOF

    sudo chown -R systest "${PIG_DESTINATION}"

    # Stop the opportunistic build process to avoid conflicts with the below invocation of mvn.
    # sudo kill -TERM \$(cat /tmp/mvn-install-pid) || true
    sudo su - systest

    # Set CDH_GBN and CM_GBN env vars
    export CDH_GBN=${CDH_GBN}
    export CM_GBN=${CM_GBN}

    # Set JAVA_HOME using bigtop-detect-javahome.
    . /usr/lib/bigtop-utils/bigtop-detect-javahome || \
        . /opt/cloudera/parcels/CDH/lib/bigtop-utils/bigtop-detect-javahome

    # user correct maven settings file
    curl http://github.mtv.cloudera.com/raw/CDH/cdh/cdh6.x/gbn-m2-settings.xml > ${PIG_DESTINATION}/mvn_settings.xml
    mvn -gs ${PIG_DESTINATION}/mvn_settings.xml -f ${PIG_DESTINATION}/cloudera-pom.xml process-resources -U -B

    eval "${E2E_TEST_DEPLOY_STRING[@]}" && eval "${E2E_TEST_EXECUTE_STRING[@]}"
    TEST_EXIT_CODE=\$?

    # Regardless of whether or not all the tests passed, move them into SSH_USER's home folder and
    # change their ownership so that we can collect them on the Jenkins slave.
    sudo chown -R "${SSH_USER}" "${PIG_DESTINATION}"
    exit \${TEST_EXIT_CODE}
__EOF

  TEST_EXIT_CODE=$?
  if [ ${TEST_EXIT_CODE} -eq 0 ]; then
    printCenteredText "All tests passed."
  else
    printCenteredText "There were test failures." >&2
  fi
}

retrieveTestResults() {
  TEST_RUNNING_HOST="${1}"
  PIG_FOLDER_NAME="${2}"
  PIG_DESTINATION=/var/tmp/"${PIG_FOLDER_NAME}"

  printCenteredText "Attempting to retrieve test results..."
  SSH_USER="${TEST_EXECUTION_HOST_SSH_USER:-${DEFAULT_TEST_EXECUTION_HOST_SSH_USER}}"
  SSH_ARGUMENTS="${TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]:-${DEFAULT_TEST_EXECUTION_HOST_SSH_ARGUMENTS[@]}}"

  # This will return either the home directory of the user on the remote host, or an empty string.
  SSH_USER_HOME=$(ssh ${SSH_ARGUMENTS} "${SSH_USER}@${TEST_RUNNING_HOST}" "getent passwd ${SSH_USER} | cut -f6 -d:")

  if [ -z "${SSH_USER_HOME}" ]; then
    printCenteredText "Could not locate home directory of user ${SSH_USER} on ${TEST_RUNNING_HOST}. Exiting..." >&2
    return 1
  fi

  if scp -r ${SSH_ARGUMENTS} \
      "${SSH_USER}@${TEST_RUNNING_HOST}":"${PIG_DESTINATION}" "${PIG_FOLDER_NAME}"; then
    printCenteredText "Test result retrieval succeeded."
  else
    printCenteredText "Test result retrieval failed. Exiting..." >&2
    return 1
  fi

  echo "generating test report..."
  ${PIG_FOLDER_NAME}/test/e2e/harness/xmlReport.pl ${PIG_FOLDER_NAME}/test/e2e/pig/testdist/out/log/`ls -t1 ${PIG_FOLDER_NAME}/test/e2e/pig/testdist/out/log | head -1` > TEST-e2e.xml
}

validateServiceHealth() {
  printCenteredText "Validating cluster health..."
  if clusterdock_run ./bin/manage_cluster cdh --cm-server-address="${CM_MASTER_HOST}" \
      --validate-service-health; then
    printCenteredText "Validated cluster health."
  else
    printCenteredText "Cluster health validation failed." >&2
    return 1
  fi
}

# Takes in one argument: either 'cloud' or 'docker' for the way hosts have been provisioned.
destroyHosts() {
  local NODE_TYPE="${1}"
  printCenteredText "Attempting to destroy hosts..."
  if [ "${NODE_TYPE}" = "cloud" ]; then
    if sudo docker run --net=host -v "${WORKSPACE}"/target:/root/deploy/cdep/target \
        -v /etc/localtime:/etc/localtime "${DOCKER_IMAGES_CDEP}":"${CDEP_DOCKER_IMAGE_TAG}" \
        ./infrastructure/cloud_provisioner.py "${CLOUD_PROVISIONING_ARGS[@]}" destroy_group; then
      printCenteredText "Host destruction succeeded."
    else
      printCenteredText "Host destruction failed. Exiting..." >&2
    fi
  elif [ "${NODE_TYPE}" = "docker" ]; then
    if clusterdock_run ./bin/housekeeping remove -n "network"${RANDOM_STRING}""; then
      printCenteredText "Docker container cluster destruction succeeded."
    else
      printCenteredText "Docker container cluster destruction failed. Exiting..." >&2
    fi
  fi
}

# The actual job execution function which takes in two arguments:
# 'cloud', 'docker', or 'preexisting_machines' for the way hosts should be provisioned;
#  and the number of hosts in the cluster.
main() {
  NODE_TYPE="${1}"
  NUMBER_OF_MACHINES="${2}"

  validateParameters "${NODE_TYPE}"

  # Source .clusterdock.sh to get clusterdock helper functions.
  source /dev/stdin <<< "$(curl -sL http://github.mtv.cloudera.com/raw/QE/clusterdock/master/.clusterdock.sh)"

  # Load all constants fo<F10r being able to use cdep out of a Docker container.
  export $(clusterdock_run ./bin/housekeeping variables)

  # Pull down cdep Docker image to guard against existing stale images.
  sudo docker pull "${DOCKER_IMAGES_CDEP}:${CDEP_DOCKER_IMAGE_TAG}"
  echo "Using cdep hash $(sudo docker run "${DOCKER_IMAGES_CDEP}:${CDEP_DOCKER_IMAGE_TAG}" git rev-parse HEAD)."

  # A random string is generated to ensure unique folder and hostnames.
  RANDOM_STRING="${RANDOM}"

  # Set hostnames depending on how we want those hosts to be created.
  if [ "${NODE_TYPE}" != "preexisting_machines" ]; then
    createHostnames "${NODE_TYPE}" "${NUMBER_OF_MACHINES}"
  fi
  echo "HOSTS: ${HOSTS}"

  # Let's also keep track of the CM master host and the host that will run tests. In this case,
  # the CM master host is the first in the group and the host on which tests are run is
  # the last node of the cluster.
  CM_MASTER_HOST=$(eval echo "${HOSTS}" | cut -d " " -f 1)
  TEST_EXECUTION_HOST=$(eval echo "${HOSTS}" | cut -d " " -f "${NUMBER_OF_MACHINES}")
  PIG_FOLDER="pig_${RANDOM_STRING}"

  if resolveCDH && resolveCM; then
    if [ "${NODE_TYPE}" = "preexisting_machines" ] || provisionHosts "${NODE_TYPE}" "${NUMBER_OF_MACHINES}"; then
      if deployCluster "${NODE_TYPE}"; then
        setupClusterTestEnvironment ${TEST_EXECUTION_HOST} "${PIG_FOLDER}" && \
        executeTests ${TEST_EXECUTION_HOST} ${CM_MASTER_HOST} " " "${PIG_FOLDER}" && \
        retrieveTestResults ${TEST_EXECUTION_HOST} "${PIG_FOLDER}"
      fi

      # Note that the default value for TEST_EXIT_CODE below is to catch cases in which tests weren't
      # executed (e.g. failure to provision or deploy hosts).
      if [ ${TEST_EXIT_CODE:-1} -ne 0 ] || [ "${ALWAYS_COLLECT_DIAGNOSTIC_BUNDLES}" = "true" ]; then
        collectDiagnosticBundles
      fi

      if [ "${KEEP_CLUSTERS_ONLINE}" != "true" ] && [ "${NODE_TYPE}" != "preexisting_machines" ]; then
        destroyHosts "${NODE_TYPE}"
      fi
    fi
  fi

  # Some of the commands above pull artifacts into the Jenkins workspace in such a way that
  # the Jenkins user may not be able to modify them (e.g. when a sudo command runs a Docker container
  # and uses a shared volume mount). To prevent this from causing us grief, just chown the workspace
  # recursively to the jenkins user.
  sudo chown -R jenkins:jenkins "${WORKSPACE}"

  # EXIT_CODE is set to non-zero only if deployment testing fails for Jenkins to mark that build
  # as failed, but for Nightly and BVT if the tests run we actually want Jenkins to analyze
  # the results on its own.
  exit ${EXIT_CODE}
}
