#!/bin/bash

ROOTDIR=/mnt/backups/bkps
WORKDIR=/mnt/backups/recovery

cd $ROOTDIR

USE_MEMORY=1G
CURLOG=$(ls -1 *-info.log | tail -n 1 | sed -e 's/\(.*\)-info.log/\1/')

usage()
{
cat<<EOF >&2
   usage: xrecovery.sh [-f <timestamp>] [-m <memory_pool>]

   -f <timestamp>: filename batch (without extension) to start recovery from, default latest
   -m <memory_pool>: memory to allocate to recovery process, expressed as 250M or 2G, default 1G

EOF

}

while  getopts "f:m:" OPTION; do
    case $OPTION in
        f)
            CURLOG=$OPTARG
            ;;
        m)
            USE_MEMORY=$OPTARG
            ;;
        ?)
        usage
        exit 1
        ;;
    esac
done

rm -rf $WORKDIR chain-search.txt chain.txt

if [ ! -f $CURLOG.tar.gz ]; then
  echo recovery: invalid starting point $CURLOG.tar.gz
  exit 1
fi

# do-while
while : ; do
  if [ ! -f $CURLOG-info.log ]; then
    echo recovery: cannot find target log $CURLOG-info.log
    exit 1
  fi
  if [ ! -f $CURLOG.tar.gz ]; then
    echo recovery: cannot find target archive $CURLOG.tar.gz
    exit 1
  fi
  # identify the type of log
  CURTYPE=$(grep 'xbackup INFO: Backup type:' $CURLOG-info.log | cut -f 6 -d " ")
  if [[ -z "${CURTYPE// }" ]]; then
    # not sure I get how this is happening
    CURTYPE=full
  fi
  echo recovery: found $CURLOG, $CURTYPE
  echo $CURLOG >> chain-search.txt
  # are we done?
  [[ $CURTYPE == full ]] && break
  echo recovery: following chain...
  # parse the current log to find the parent
  NEWLOG=$(grep -- --incremental-basedir $CURLOG-info.log | perl -pe 's~.*incremental-basedir /[^[:space:]]*/([^[:space:]]*).*?~\1~')
  if [[ $CURLOG == $NEWLOG || "$NEWLOG" == "" ]]; then
    echo recovery: could not parse next target, failure
    exit 1
  else
    CURLOG=$NEWLOG
  fi
done

# the action chain is backward
tac chain-search.txt > chain.txt
rm chain-search.txt

echo recovery: recovery plan ready!

CURLINE=1
MAXLINE=$(cat chain.txt | wc -l)
while read line; do
  rm -rf $line
  tar -zxf $line.tar.gz
  if [ $MAXLINE -eq 1 ]; then
    echo recovery: process single backup $line
    xtrabackup --use-memory $USE_MEMORY --prepare --target-dir=$line
    if [ $? -ne 0 ]; then
      echo recovery: backup preparation failed! not deleting workdir
      exit 1
    fi
    mv $line $WORKDIR
  elif [ $CURLINE -eq 1 ]; then
    echo recovery: obtain full backup $line
    xtrabackup --use-memory $USE_MEMORY --prepare --apply-log-only --target-dir=$line
    if [ $? -ne 0 ]; then
      echo recovery: initial backup preparation failed! not deleting workdir
      exit 1
    fi
    mv $line $WORKDIR
  elif [ $CURLINE -lt $MAXLINE ]; then
    echo recovery: apply intermediate incremental $line
    xtrabackup --use-memory $USE_MEMORY --prepare --apply-log-only --target-dir=$WORKDIR --incremental-dir=`pwd`/$line
    if [ $? -ne 0 ]; then
      echo recovery: intermediate recovery failed! not deleting workdir
      exit 1
    fi
    rm -rf $line
  else
    echo recovery: apply final incremental $line
    xtrabackup --use-memory $USE_MEMORY --prepare --target-dir=$WORKDIR --incremental-dir=$line
    if [ $? -ne 0 ]; then
      echo recovery: final incremental failed! not deleting workdir
      exit 1
    fi
    rm -rf $line
  fi
  CURLINE=$(($CURLINE+1))
done < chain.txt

rm chain.txt

if ! service mysql status; then
  echo recovery: preparations complete, swapping new datadir
  /root/xrecovery-final.sh
else
  echo recovery: mysql is running, bouncing container
  touch /root/pending-restore
  service mysql stop
  exit 0
fi

echo recovery: complete
exit 0
