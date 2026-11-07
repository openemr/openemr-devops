#!/bin/bash
# shellcheck disable=SC2312

SWAPAMT=0
REPOOWNER=openemr
REPOBRANCH=master
SKIPOSCHECK=0
TARGETOS="Ubuntu"
TARGETVERSION="24"
displayHelp () {
cat <<EOF
OpenEMR appliance launcher
usage: launch.sh -sobfh
      -s: amount of swap to allocate, in gigabytes [${SWAPAMT}]
      -o: specify owner of devops repo [${REPOOWNER}]
      -b: devops repo branch to load [${REPOBRANCH}]
      -f: force install even if OS match fails [${TARGETOS} ${TARGETVERSION}]
      -h: display this help
EOF
}

allocateSwap() {
  SWAPPATHNAME=/mnt/auto.swap
  if [[ "${SWAPAMT}" != 0 ]]; then
    echo "Allocating ${SWAPAMT}G swap..."
    fallocate -l "${SWAPAMT}G" "${SWAPPATHNAME}"
    mkswap "${SWAPPATHNAME}"
    chmod 600 "${SWAPPATHNAME}"
    swapon "${SWAPPATHNAME}"
    echo "${SWAPPATHNAME}  none  swap  sw 0  0" >> /etc/fstab
  else
    echo Skipping swap allocation...
  fi
}

exec > /var/log/appliance-launch.log 2>&1

while getopts "hs:b:o:f" opt; do
  case ${opt} in
    s)
      SWAPAMT=${OPTARG}
      ;;
    o)
      REPOOWNER=${OPTARG}
      ;;
    b)
      REPOBRANCH=${OPTARG}
      ;;
    f)
      SKIPOSCHECK=1
      ;;
    h)
      displayHelp
      exit 0
      ;;  
    \?)
      echo "Invalid option: -${opt}" >&2
      exit 1
      ;;
    *)
      echo "unknown case in getopts parse?"
      exit 1
      ;;
  esac
done



main () {

  [[ "${EUID}" -eq 0 ]] || { echo "launch.sh: root required" 1>&2 ; exit 1; }

  if [[ "${SKIPOSCHECK}" -eq 0 ]]; then
    [[ -f /etc/os-release ]] || { echo "launch.sh: can't perform OS check" 1>&2 ; exit 1; }
    [[ $(grep -ioP '^NAME=\K.+' /etc/os-release) == \"${TARGETOS}\" ]] || { echo "OS match failed against ${TARGETOS}" 1>&2 ; exit 1; }
    [[ $(grep -ioP '^VERSION_ID=\K.+' /etc/os-release) == \"${TARGETVERSION}* ]] || { echo "OS match failed against ${TARGETVERSION}" 1>&2 ; exit 1; }
  fi

  cd /root || exit 1

  allocateSwap

  # Make sure we don't fail out if there is an interactive prompt... go with defaults
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get dist-upgrade -y
  apt autoremove -y
  apt-get install jq git duplicity containerd docker-compose-v2 python3-boto3 -y

  mkdir -p /opt/appliance/backups/in/site /opt/appliance/backups/in/mysql \
    /opt/appliance/backups/out

  git clone --single-branch --branch "${REPOBRANCH}" https://github.com/"${REPOOWNER}"/openemr-devops.git
  cd openemr-devops/packages/appliance || exit 1
 
  docker compose up -d --build

  until [[ -n "${CONTAINER}" ]]
  do
    echo "waiting on composer start..."
    sleep 5
    CONTAINER="$(docker compose ps --services openemr -qa)"
  done

  until [[ "$(docker container inspect "${CONTAINER}"| jq '.[].State.Health.Status' -r)" == "healthy" ]]
  do
      echo "waiting on service start..."
      sleep 5
  done

  pushd ../../utilities/mariadb-backup-manager || exit 1
  chmod a+x ./install.sh
  ./install.sh -p appliance --cycles 2 --incrementals 6
  popd || exit 1

  chmod a+x backup.sh restore.sh
  cp backup.sh /etc/cron.daily/duplicity-backups

  curl -L --fail-with-body -o oce-manage-users.phar https://github.com/opencoreemr/oce-cli-manage-users/releases/latest/download/oce-manage-users.phar || exit 1
  docker compose -p appliance cp oce-manage-users.phar openemr:/usr/local/bin
  docker compose -p appliance exec openemr chown root:root /usr/local/bin/oce-manage-users.phar
  docker compose -p appliance exec openemr chmod +x /usr/local/bin/oce-manage-users.phar

  echo "launch.sh: done"
}

main
