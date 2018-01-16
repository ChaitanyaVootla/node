#!/bin/bash
set -e
set -o pipefail

# initScript for Ubuntu 16.04 and Docker 17.06
# ------------------------------------------------------------------------------

readonly DOCKER_VERSION="17.06.0"
readonly SWAP_FILE_PATH="/root/.__sh_swap__"
export docker_restart=false

check_init_input() {
  local expected_envs=(
    'NODE_SHIPCTL_LOCATION'
    'NODE_ARCHITECTURE'
    'NODE_OPERATING_SYSTEM'
    'LEGACY_CI_CEXEC_LOCATION_ON_HOST'
    'SHIPPABLE_RELEASE_VERSION'
    'EXEC_IMAGE'
    'REQKICK_DIR'
    'IS_SWAP_ENABLED'
  )

  check_envs "${expected_envs[@]}"
}

create_shippable_dir() {
  create_dir_cmd="mkdir -p /home/shippable"
  exec_cmd "$create_dir_cmd"
}

install_prereqs() {
  echo "Installing prerequisite binaries"

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"

  install_prereqs_cmd="apt-get -yy install apt-transport-https git python-pip software-properties-common ca-certificates curl wget tar linux-image-extra-virtual linux-image-extra-`uname -r`"
  exec_cmd "$install_prereqs_cmd"

  add_docker_repo_keys='curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -'
  exec_cmd "$add_docker_repo_keys"

  add_docker_repo='add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"'
  exec_cmd "$add_docker_repo"

  pushd /tmp
  echo "Installing node 4.8.5"

  get_node_tar_cmd="wget https://nodejs.org/dist/v4.8.5/node-v4.8.5-linux-x64.tar.xz"
  exec_cmd "$get_node_tar_cmd"

  node_extract_cmd="tar -xf node-v4.8.5-linux-x64.tar.xz"
  exec_cmd "$node_extract_cmd"

  node_copy_cmd="cp -Rf node-v4.8.5-linux-x64/{bin,include,lib,share} /usr/local"
  exec_cmd "$node_copy_cmd"

  check_node_version_cmd="node -v"
  exec_cmd "$check_node_version_cmd"
  popd

  echo "Installing shipctl components"
  exec_cmd "$NODE_SHIPCTL_LOCATION/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM/install.sh"

  exec_cmd "$update_cmd"
}

check_swap() {
  echo "Checking for swap space"

  swap_available=$(free | grep Swap | awk '{print $2}')
  if [ $swap_available -eq 0 ]; then
    echo "No swap space available, adding swap"
    is_swap_required=true
  else
    echo "Swap space available, not adding"
  fi
}

add_swap() {
  echo "Adding swap file"
  echo "Creating Swap file at: $SWAP_FILE_PATH"
  add_swap_file="touch $SWAP_FILE_PATH"
  exec_cmd "$add_swap_file"

  swap_size=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  swap_size=$(($swap_size/1024))
  echo "Allocating swap of: $swap_size MB"
  initialize_file="dd if=/dev/zero of=$SWAP_FILE_PATH bs=1M count=$swap_size"
  exec_cmd "$initialize_file"

  echo "Updating Swap file permissions"
  update_permissions="chmod -c 600 $SWAP_FILE_PATH"
  exec_cmd "$update_permissions"

  echo "Setting up Swap area on the device"
  initialize_swap="mkswap $SWAP_FILE_PATH"
  exec_cmd "$initialize_swap"

  echo "Turning on Swap"
  turn_swap_on="swapon $SWAP_FILE_PATH"
  exec_cmd "$turn_swap_on"

}

check_fstab_entry() {
  echo "Checking fstab entries"

  if grep -q $SWAP_FILE_PATH /etc/fstab; then
    exec_cmd "echo /etc/fstab updated, swap check complete"
  else
    echo "No entry in /etc/fstab, updating ..."
    add_swap_to_fstab="echo $SWAP_FILE_PATH none swap sw 0 0 | tee -a /etc/fstab"
    exec_cmd "$add_swap_to_fstab"
    exec_cmd "echo /etc/fstab updated"
  fi
}

initialize_swap() {
  check_swap
  if [ "$is_swap_required" == true ]; then
    add_swap
  fi
  check_fstab_entry
}

docker_install() {
  echo "Installing docker"

  install_docker="apt-get install -q --force-yes -y -o Dpkg::Options::='--force-confnew' docker-ce=$DOCKER_VERSION~ce-0~ubuntu"
  exec_cmd "$install_docker"

  get_static_docker_binary="wget https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER_VERSION-ce.tgz -P /tmp/docker"
  exec_cmd "$get_static_docker_binary"

  extract_static_docker_binary="tar -xzf /tmp/docker/docker-$DOCKER_VERSION-ce.tgz --directory /opt"
  exec_cmd "$extract_static_docker_binary"

  remove_static_docker_binary='rm -rf /tmp/docker'
  exec_cmd "$remove_static_docker_binary"
}

check_docker_opts() {
  # SHIPPABLE docker options required for every node
  echo "Checking docker options"

  SHIPPABLE_DOCKER_OPTS='DOCKER_OPTS="$DOCKER_OPTS -H unix:///var/run/docker.sock -g=/data --dns 8.8.8.8 --dns 8.8.4.4"'
  opts_exist=$(sh -c "grep '$SHIPPABLE_DOCKER_OPTS' /etc/default/docker || echo ''")

  # DOCKER_OPTS do not exist or match.
  if [ -z "$opts_exist" ]; then
    echo "Removing existing DOCKER_OPTS in /etc/default/docker, if any"
    sed -i '/^DOCKER_OPTS/d' "/etc/default/docker"

    echo "Appending DOCKER_OPTS to /etc/default/docker"
    sh -c "echo '$SHIPPABLE_DOCKER_OPTS' >> /etc/default/docker"
    docker_restart=true
  else
    echo "Shippable docker options already present in /etc/default/docker"
  fi

  ## remove the docker option to listen on all ports
  echo "Disabling docker tcp listener"
  sh -c "sed -e s/\"-H tcp:\/\/0.0.0.0:4243\"//g -i /etc/default/docker"
}

restart_docker_service() {
  echo "checking if docker restart is necessary"
  if [ $docker_restart == true ]; then
    echo "restarting docker service on reset"
    exec_cmd "service docker restart"
  else
    echo "docker_restart set to false, not restarting docker daemon"
  fi
}

install_ntp() {
  {
    check_ntp=$(service --status-all 2>&1 | grep ntp)
  } || {
    true
  }

  if [ ! -z "$check_ntp" ]; then
    echo "NTP already installed, skipping."
  else
    echo "Installing NTP"
    exec_cmd "apt-get install -y ntp"
    exec_cmd "service ntp restart"
  fi
}

pull_cexec() {
  __process_marker "Pulling cexec"
  if [ -d "$LEGACY_CI_CEXEC_LOCATION_ON_HOST" ]; then
    exec_cmd "rm -rf $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  fi
  exec_cmd "git clone https://github.com/Shippable/cexec.git $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  __process_msg "Checking out tag: $SHIPPABLE_RELEASE_VERSION in $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  pushd $LEGACY_CI_CEXEC_LOCATION_ON_HOST
  exec_cmd "git checkout $SHIPPABLE_RELEASE_VERSION"
  popd
}

pull_reqProc() {
  __process_marker "Pulling reqProc..."
  docker pull $EXEC_IMAGE
}

clone_reqKick() {
  __process_marker "Cloning reqKick..."
  rm -rf $REQKICK_DIR
  git clone https://github.com/Shippable/reqKick.git $REQKICK_DIR
  pushd $REQKICK_DIR
    git checkout $SHIPPABLE_RELEASE_VERSION
    npm install
  popd
}

before_exit() {
  echo $1
  echo $2

  echo "Node init script completed"
}

main() {
  check_init_input

  trap before_exit EXIT
  exec_grp "create_shippable_dir"

  trap before_exit EXIT
  exec_grp "install_prereqs"

  if [ "$IS_SWAP_ENABLED" == "true" ]; then
    trap before_exit EXIT
    exec_grp "initialize_swap"
  fi

  trap before_exit EXIT
  exec_grp "docker_install"

  trap before_exit EXIT
  exec_grp "check_docker_opts"

  trap before_exit EXIT
  exec_grp "restart_docker_service"

  trap before_exit EXIT
  exec_grp "install_ntp"

  trap before_exit EXIT
  exec_grp "pull_cexec"

  trap before_exit EXIT
  exec_grp "pull_reqProc"

  trap before_exit EXIT
  exec_grp "clone_reqKick"
}

main
