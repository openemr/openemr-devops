#!/bin/bash

##############################################################
#                                                            #
# Bash script wrapper for creating, preparing and storing    #
#   XtraBackup based backups for MySQL.                      #
#                                                            #
# @author Jervin Real <jervin.real@percona.com>              #
#                                                            #
##############################################################

# set this only if you don't have the mysql and xtrabackup binaries in your PATH
# export PATH=/wok/bin/xtrabackup/2.0.0/bin:/opt/percona/server/bin:$PATH

# print usage info
usage()
{
cat<<EOF >&2
   usage: xbackup.sh -t <type> -s timestamp -i incremental-basedir -b backup-dir -d datadir -f -l binlogs -u initial-database -m memory-pool -a

   Only <type> is mandatory, and it can be one of full or incr

   ts is a timestamp to mark the backup with. defaults to $(date +%Y-%m-%d_%H_%M_%S)
   incremental-basedir will be passed to innobackupex as --incremental-basedir, if present and type was incr. defaults to the last backup taken
   datadir is mysql's datadir, needed if it can't be found on my.cnf or obtained from mysql
   -m is the memory pool available for APPLY_LOG, expressed as 256M or 1G
   -f will force the script to run, even if a lock file was present
   binlogs is the binlgo directory. if this option is set, binlogs will be copied with the backup. by default, they are not.
   -u will (re)set the target DB for the backup storage table, must be done once
   -a will force the creation of the backup storage table, then exit

EOF

}

# Timestamp for the backup, if not called from xbackup-run.sh
CURDATE=$(date +%Y-%m-%d_%H_%M_%S)

# Type of backup, accepts 'full' or 'incr'
BKP_TYPE=

# If type is incremental, and this options is specified, it will be used as
#    --incremental-basedir option for innobackupex.
INC_BSEDIR=

# Base dir, this is where the backup will be initially saved.
WORK_DIR=/root/xtrabackup/work

# This is where the backups will be stored after verification. If this is empty
# backups will be stored within the WORK_DIR. This should already exist as we will
# not try to create one automatically for safety purpose. Within ths directory
# must exist a 'bkps' and 'bnlg' subdirectories. In absence of a final stor, backups
# and binlogs will be saved to WORK_DIR
STOR_DIR=/mnt/backups

# If you want to ship the backups to a remote server, specify
# here the SSH username and password and the remote directory
# for the backups. Absence of neither disables remote shipping
# of backups
#RMTE_DIR=/sbx/sb/xbackups/rmte
#RMTE_SSH="revin@127.0.0.1"

# Where are the MySQL data and binlog directories
DATADIR=/var/lib/mysql
BNLGDIR=/var/lib/mysql

# Include binary logs for each backup. Binary logs are incrementally
# collected to $STOR_DIR/bnlg. The amount of binlog kept depends on
# the oldest backup that exists
COPY_BINLOGS=1

# Used as --use-memory option for innobackupex when APPLY_LOG is
# enabled
USE_MEMORY=1G

RESETDATABASE=

CREATETABLE=

while  getopts "t:s:i:b:d:l:u:m:fa" OPTION; do
    case $OPTION in
        t)
            BKP_TYPE=$OPTARG
            ;;
        s)
            CURDATE=$OPTARG
            ;;
        i)
            INC_BSEDIR=$OPTARG
            ;;
        b)
            WORK_DIR=$OPTARG
            ;;
        d)
            DATADIR=$OPTARG
            ;;
        l)
            BNLGDIR=$OPTARG
            COPY_BINLOGS=1
            ;;
        u)
            NEWDATABASENAME=$OPTARG
            RESETDATABASE=1
            ;;
        m)
            USE_MEMORY=$OPTARG
            ;;
        f)
            rm -f /tmp/xbackup.lock
            ;;
        a)
          CREATETABLE=1
            ;;
        ?)
        usage
        exit 1
        ;;
    esac
done

# We need at least one arg, the backup type
[ "x$CREATETABLE" != "x1" ] && [ $# -lt 1 -o -z "$BKP_TYPE" ] && { usage; exit 1; }

# log-bin filename format, used when copying binary logs
BNLGFMT=mysql-bin

# Whether to keep a prepared copy, sueful for
# verification that the backup is good for use.
# Verification is done on a copy under WORK_DIR and an untouched
# copy is stored on STOR_DIR
APPLY_LOG=0

# Whether to compress backups within STOR_DIR
STOR_CMP=1

# When backing up from a Galera/XtraDB cluster node
GALERA_INFO=0

INF_FILE_STOR="${STOR_DIR}/bkps/${CURDATE}-info.log"
LOG_FILE="${WORK_DIR}/bkps/${CURDATE}.log"
INF_FILE_WORK="${WORK_DIR}/bkps/${CURDATE}-info.log"

# How many backup sets do you want to keep, these are the
# count of full backups plus their incrementals.
# i.e. is you set 2, there will be 2 full backups + their
# incrementals
STORE=2

KEEP_LCL=0

# Will be used as --defaults-file for innobackupex and mysql, must not be empty
#DEFAULTS_FILE=/sbx/msb/msb_5_5_38/my.sandbox.cnf
DEFAULTS_FILE=/root/innobackupex.cnf

# holds name of DB for xtradb_backups table
DATABASE_FILE=/root/xtrabackup.database.txt

if [ "x$RESETDATABASE" == "x1" ]; then
  # write the file containing the name of the DB xtrabackup should store data in
  echo $NEWDATABASENAME > $DATABASE_FILE
  chmod 600 $DATABASE_FILE
fi

if [ ! -f $DATABASE_FILE ]; then
  echo no defined xtradb reporting database: cannot proceed
  exit 1
else
  XTRABACKUP_RECORDS=$(cat $DATABASE_FILE)
fi

# mysql client command line that will give access to the schema
# and table where backups information will be stored. See
# backup table structure below.
MY="mysql --defaults-file=$DEFAULTS_FILE --database=$XTRABACKUP_RECORDS"

# How to flush logs, on versions < 5.5.3, the BINARY clause
# is not yet supported. Not used at the moment.
FLOGS="${MY} -BNe 'FLUSH BINARY LOGS'"

# Table definition where backup information will be stored.
TBL=$(cat <<EOF
CREATE TABLE xtradb_backups (
  id int(10) unsigned NOT NULL auto_increment,
  started_at timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP,
  ends_at datetime NOT NULL,
  size varchar(15) default NULL,
  path varchar(120) default NULL,
  type enum('full','incr') NOT NULL default 'full',
  incrbase datetime default NULL,
  weekno tinyint(3) unsigned NOT NULL default '0',
  baseid int(10) unsigned NOT NULL default '0',
  PRIMARY KEY  (\`id\`)
) ENGINE=InnoDB;
EOF
)

##############################################################
#      Modifications not recommended beyond this point.      #
##############################################################

_df() {
   df -P -B 1K $1|tail -n-1|awk '{print $4}'
}

_df_h() {
   df -Ph $1|tail -n-1|awk '{print $4}'
}

_du_r() {
   du -B 1K --max-depth=0 $1|awk '{print $1}'
}

_du_h() {
   du -h --max-depth=0 $1|awk '{print $1}'
}

_s_inf() {
   echo "$(date +%Y-%m-%d_%H_%M_%S) xbackup $1" | tee -a $INF_FILE_WORK
}

_echo() {
   echo "$(date +%Y-%m-%d_%H_%M_%S) xbackup $1"
}

_d_inf() {
   echo "$(date +%Y-%m-%d_%H_%M_%S) xbackup $1" | tee -a $INF_FILE_WORK
   exit 1
}

_sql_query() {
   local _out="/tmp/xbackup.sql.out"
   local _ret=0
   local _try=3
   local _sleep=30

   for r in {1..$_try}; do
      $MY -BNe "${1}" > /tmp/xbackup.sql.out 2>&1
      _ret=${PIPESTATUS[0]}
      if [ "x$_ret" != "x0" ]; then
         sleep $_sleep
      else
         cat $_out
         rm -rf $_out
         break
      fi
   done

   if [ "x$_ret" != "x0" ]; then
      _s_inf "FATAL: Failed to execute SQL after attempting $_try times every $_sleep seconds, giving up!" | tee -a $_out
      _s_inf "SQL: ${1}" | tee -a $_out
      cat $_out
      kill -s TERM $XBACKUP_PID
   fi
}

#
# Returns a list of full backups (old ones > $STORE) whose
#   set we will prune later
#
_sql_prune_base() {
   _sql=$(cat <<EOF
   SELECT COALESCE(GROUP_CONCAT(id SEPARATOR ','),'')
   FROM (
      SELECT id
      FROM xtradb_backups
      WHERE type = 'full'
      ORDER BY started_at DESC
      LIMIT ${STORE},999999
   ) t
EOF
   )

   _sql_query "${_sql}"
}

#
# Returns a list of backups based on ids of full backups
#
_sql_prune_list() {
   _sql=$(cat <<EOF
      SELECT
         CONCAT(GROUP_CONCAT(DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s') SEPARATOR '* '),'*')
      FROM xtradb_backups
      WHERE id IN (${1}) OR
         baseid IN (${1})
      ORDER BY id
EOF
   )

   _sql_query "${_sql}"
}

#
# When deleting old backups
#
_sql_prune_rows() {
   _sql=$(cat <<EOF
   DELETE FROM xtradb_backups
   WHERE id IN (${1}) OR
      baseid IN (${1})
EOF
   )

   _sql_query "${_sql}"
}

#
# When doing incremental backups, the results
#   will be used for out --incremental-dir
#
_sql_last_backup() {
   _sql=$(cat <<EOF
   SELECT
      DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s'), weekno
   FROM xtradb_backups
   ORDER BY started_at DESC
   LIMIT 1
EOF
   )

   _sql_query "${_sql}"
}

#
# When COPY_BINLOGS is enabled, we determine what was our
#   oldest backups, from this we can determine how far back
#   we should keep a copy of the binary logs
#
_sql_first_backup_elapsed() {
   _sql=$(cat <<EOF
   SELECT
      CEIL((UNIX_TIMESTAMP()-UNIX_TIMESTAMP(started_at))/60) AS elapsed
   FROM xtradb_backups
   ORDER BY started_at ASC
   LIMIT 1
EOF
   )

   _sql_query "${_sql}"
}

#
# Save backup information info percona.backups
#
_sql_save_bkp() {
   _sql=$(cat <<EOF
   INSERT INTO xtradb_backups
      (started_at, ends_at, size, path,
      type, incrbase, weekno, baseid)
   VALUES(${1},'${2}',
      '${3}','${4}',
      '${BKP_TYPE}',${5},
      ${6}, ${7})
EOF
   )

   _sql_query "${_sql}"
}

#
# When taking incremental backup, we check from
#   percona.backups what will be our
#   --incremental-basedir
#
_sql_incr_bsedir() {
   _sql=$(cat <<EOF
   SELECT
      DATE_FORMAT(started_at,'%Y-%m-%d_%H_%i_%s'), id
   FROM xtradb_backups
   WHERE type = 'full' AND
      weekno = ${_week_no}
   ORDER BY started_at DESC
   LIMIT 1
EOF
      )

   _sql_query "${_sql}"
}

#
# Get current week number from the database, we do this as system time
#   could differ from DB time
#
_sql_get_week_no() {
   _sql=$(cat <<EOF
    SELECT DATE_FORMAT(STR_TO_DATE('${CURDATE}','%Y-%m-%d_%H_%i_%s'),'%U')
EOF
  )
   _sql_query "${_sql}"
}

_error_handler() {
   [ -f /tmp/xbackup.sql.out ] && cat /tmp/xbackup.sql.out \
      && rm -rf /tmp/xbackup.sql.out
   _d_inf "FATAL: Backup failed, please investigate!"
}

trap '_error_handler' TERM
XBACKUP_PID=$$

# do we need to do first-time table creation?
if [ "x$CREATETABLE" == "x1" ]; then
  echo attempting schema creation...
  _sql_query "$TBL"
  echo schema creation success!
  exit 0
fi

if [ -f /tmp/xbackup.lock ]; then
   _d_inf "ERROR: Another backup is still running or a previous \
      backup failed, please investigate!";
fi
touch /tmp/xbackup.lock

if [ ! -n "${BKP_TYPE}" ]; then _d_inf "ERROR: No backup type specified!"; fi
_s_inf "INFO: Backup type: ${BKP_TYPE}"

[ -d $STOR_DIR ] || \
   _d_inf "ERROR: STOR_DIR ${STOR_DIR} does not exist, \
      I will not create this automatically!"
[ -d $WORK_DIR ] || \
   _d_inf "ERROR: WORK_DIR ${WORK_DIR} does not exist, \
      I will not create this automatically!"

if [ "x$COPY_BINLOGS" == "x1" ]; then
   mkdir -p "${STOR_DIR}/bnlg" || \
      _d_inf "ERROR: ${STOR_DIR}/bnlg does no exist and cannot be created \
         automatically!"
fi

mkdir -p "${STOR_DIR}/bkps" || \
   _d_inf "ERROR: ${STOR_DIR}/bkps does no exist and cannot be created \
      automatically!"

mkdir -p "${WORK_DIR}/bkps" || \
   _d_inf "ERROR: ${WORK_DIR}/bkps does no exist and cannot be created \
      automatically!"

_start_backup_date=`date`
_s_inf "INFO: Backup job started: ${_start_backup_date}"

DEFAULTS_FILE_FLAG=
[ -n "$DEFAULTS_FILE" ] && DEFAULTS_FILE_FLAG="--defaults-file=${DEFAULTS_FILE}"
# Check for innobackupex
_ibx=`which innobackupex`
if [ "$?" -gt 0 ]; then _d_inf "ERROR: Could not find innobackupex binary!"; fi
if [ -n $DEFAULTS_FILE ]; then _ibx="${_ibx} ${DEFAULTS_FILE_FLAG}"; fi
if [ "x$GALERA_INFO" == "x1" ]; then _ibx="${_ibx} --galera-info"; fi

_ibx_bkp="${_ibx} --no-timestamp"
_this_bkp="${WORK_DIR}/bkps/${CURDATE}"
[ "x${STOR_CMP}" == "x1" ] && _this_bkp_stored="${STOR_DIR}/bkps/${CURDATE}.tar.gz" || \
   _this_bkp_stored="${STOR_DIR}/bkps/${CURDATE}"
set -- $(_sql_last_backup)
_last_bkp=$1
_week_no=$2

if [ -n "$STOR_DIR" ]; then _this_stor=$STOR_DIR
elif [ $KEEP_LCL -eq 1 ]; then _this_stor=$WORK_DIR
else _this_stor=''
fi

#
# Determine what will be our --incremental-basedir
#
if [ "${BKP_TYPE}" == "incr" ];
then
   if [ -n "${INC_BSEDIR}" ];
   then
      if [ ! -d ${WORK_DIR}/bkps/${INC_BSEDIR} ];
      then
         _d_inf "ERROR: Specified incremental basedir ${WORK_DIR}/bkps/${_inc_basedir} does not exist.";
      fi

      _inc_basedir=$INC_BSEDIR
   else
      _inc_basedir=$_last_bkp
   fi

   if [ ! -n "$_inc_basedir" ];
   then
      _d_inf "ERROR: No valid incremental basedir found!";
   fi

   ( [ "x$APPLY_LOG" == "x1" ] || [ "x$STOR_CMP" == "x1" ] ) && \
      _inc_basedir_path="${WORK_DIR}/bkps/${_inc_basedir}" || \
      _inc_basedir_path="${STOR_DIR}/bkps/${_inc_basedir}"

   if [ ! -d "${_inc_basedir_path}" ];
   then
      _d_inf "ERROR: Incremental basedir ${_inc_basedir_path} does not exist.";
   fi

   _ibx_bkp="${_ibx_bkp} --incremental ${_this_bkp} --incremental-basedir ${_inc_basedir_path}"
   _echo "INFO: Running incremental backup from basedir ${_inc_basedir_path}"
else
   _ibx_bkp="${_ibx_bkp} ${_this_bkp}"
   _week_no=$(_sql_get_week_no)
   _echo "INFO: Running full backup (week no: ${_week_no}) ${_this_bkp}"
fi

# Check for work directory
if [ ! -d ${WORK_DIR} ]; then _d_inf "ERROR: XtraBackup work directory does not exist"; fi

DATASIZE=$(_du_r $DATADIR)
DISKSPCE=$(_df $WORK_DIR)
HASSPACE=`echo "${DATASIZE} ${DISKSPCE}"|awk '{if($1 < $2) {print 1} else {print 0}}'`
NOSPACE=0

_echo "INFO: Checking disk space ... (data: $DATASIZE) (disk: $DISKSPCE)"
[ "$HASSPACE" -eq "$NOSPACE" ] && \
   _d_inf "ERROR: Insufficient space on backup directory!"

echo
_s_inf "INFO: Xtrabackup started: `date`"
echo

# Keep track if any errors happen
_status=0

cd $WORK_DIR/bkps/
_s_inf "INFO: Backing up with: $_ibx_bkp"
$_ibx_bkp
RETVAR=$?

_end_backup_date=`date`
echo
_s_inf "INFO: Xtrabackup finished: ${_end_backup_date}"
echo

# Check the exit status from innobackupex, but dont exit right away if it failed
if [ "$RETVAR" -gt 0 ]; then
   _d_inf "ERROR: non-zero exit status of xtrabackup during backup. \
      Something may have failed!";
fi

if [ $COPY_BINLOGS -eq 1 ]; then
# Sync the binary logs to local stor first.
echo
_echo "INFO: Syncing binary log snapshots"
if [ -n "$_last_bkp" ]; then
   _first_bkp_since=$(_sql_first_backup_elapsed)
   > $WORK_DIR/bkps/binlog.index

   _echo "INFO: Getting a list of binary logs to copy"
   for f in $(cat $BNLGDIR/$BNLGFMT.index); do
      echo $(basename $f) >> $WORK_DIR/bkps/binlog.index
   done

   if [ "$STOR_CMP" == 1 ]; then
      if [ -f "$STOR_DIR/bkps/${_last_bkp}-xtrabackup_binlog_info.log" ]; then
         _xbinlog_info=$STOR_DIR/bkps/${_last_bkp}-xtrabackup_binlog_info.log
      elif [ -f "$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info" ]; then
         _xbinlog_info=$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info
      else
         _xbinlog_info=
      fi
   elif [ -f "$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info" ]; then
      _xbinlog_info=$STOR_DIR/bkps/${_last_bkp}/xtrabackup_binlog_info
   else
      _xbinlog_info=
   fi

   _s_inf "INFO: binlog information at ${_xbinlog_info}"

   if [ -n "$_xbinlog_info" -a -f "$_xbinlog_info" ]; then
      _echo "INFO: Found last binlog information $_xbinlog_info"

      _last_binlog=$(cat $_xbinlog_info|awk '{print $1}')

      cd $BNLGDIR

      for f in $(grep -A $(cat $WORK_DIR/bkps/binlog.index|wc -l) "${_last_binlog}" $WORK_DIR/bkps/binlog.index); do
         if [ "$STOR_CMP" == 1 ]; then
            [ -f "${_this_stor}/bnlg/${f}.tar.gz" ] && rm -rf "${_this_stor}/bnlg/${f}.tar.gz"
            tar czvf "${_this_stor}/bnlg/${f}.tar.gz" $f
         else
            [ -f "${_this_stor}/bnlg/${f}" ] && rm -rf "${_this_stor}/bnlg/${f}"
            cp -v $f "${_this_stor}/bnlg/"
         fi
      done

      if [ -f "${_this_stor}/bnlg/${BNLGFMT}.index" ]; then rm -rf "${_this_stor}/bnlg/${BNLGFMT}.index"; fi
      cp ${BNLGFMT}.index ${_this_stor}/bnlg/${BNLGFMT}.index
      cd $WORK_DIR/bkps/
   fi

   if [ -n "${_first_bkp_since}" -a "${_first_bkp_since}" -gt 0 ]; then
      _echo "INFO: Deleting archived binary logs older than ${_first_bkp_since} minutes ago"
      find ${_this_stor}/bnlg/ -mmin +$_first_bkp_since -exec rm -rf {} \;
   fi
fi
_echo " ... done"
fi
#
# Create copies of the backup if STOR_DIR and RMTE_DIR+RMTE_SSH is
#   specified.
#
if [ -n "$STOR_DIR" ]; then
   echo
   _echo "INFO: Copying to immediate storage ${STOR_DIR}/bkps/"
   if [ "$STOR_CMP" == 1 ]; then
      tar czvf ${STOR_DIR}/bkps/${CURDATE}.tar.gz $CURDATE
      ret=$?
      [ -f $_this_bkp/xtrabackup_binlog_info ] \
         && cp $_this_bkp/xtrabackup_binlog_info $STOR_DIR/bkps/${CURDATE}-xtrabackup_binlog_info.log
   else
      cp -r $_this_bkp* $STOR_DIR/bkps/
      ret=$?
   fi

   if [ "x$ret" != "x0" ]; then
      _s_inf "WARNING: Failed to copy ${_this_bkp} to ${STOR_DIR}/bkps/"
      _s_inf "   I will not be able to delete old backups from your WORK_DIR";
   # Delete backup on work dir if no apply log is needed
   elif [ "x$APPLY_LOG" == "x0" ]; then
      _echo "INFO: Cleaning up ${WORK_DIR}/bkps/"
      cd $WORK_DIR/bkps/
      if [ "x$STOR_CMP" != "x1" ]; then
         _rxp="$CURDATE[-info]?+.log"
      else
         _rxp="$CURDATE[-info.log]?"
      fi
      _echo "\"ls | grep -Ev $_rxp\""
      ls | grep -Ev "$_rxp"
      for f in $(ls | grep -Ev $_rxp); do rm -rf $f; done
   # We also delete the previous incremental if the backup has been successful
   elif [ "${BKP_TYPE}" == "incr" ]; then
      _echo "INFO: Deleting previous incremental ${WORK_DIR}/bkps/${_inc_basedir}"
      rm -rf ${WORK_DIR}/bkps/${_inc_basedir}*;
   elif [ "${BKP_TYPE}" == "full" ]; then
      _echo "INFO: Deleting previous work backups $(find $WORK_DIR/bkps/ -maxdepth 1 -mindepth 1|grep -v ${CURDATE}|xargs)"
      rm -rf $(find $WORK_DIR/bkps/ -maxdepth 1 -mindepth 1|grep -v ${CURDATE}|xargs)
   fi
   _echo " ... done"
fi

if [[ -n "$RMTE_DIR" && -n "$RMTE_SSH" ]]; then
   echo
   _echo "INFO: Syncing backup sets to remote $RMTE_SSH:$RMTE_DIR/"
   rsync -avzp --delete -e ssh $STOR_DIR/ $RMTE_SSH:$RMTE_DIR/
   if [ "$?" -gt 0 ]; then _s_inf "WARNING: Failed to sync ${STOR_DIR} to $RMTE_SSH:$RMTE_DIR/"; fi
   _echo " ... done"
fi

if [ "${BKP_TYPE}" == "incr" ]; then
   set -- $(_sql_incr_bsedir $_week_no)
   _incr_base=$1
   _incr_baseid=$2
   _incr_basedir=${_incr_base}
else
   _incr_baseid=0
   _incr_basedir='0000-00-00_00_00_00'
fi

# Start, whether apply log is enabled
if [ "$APPLY_LOG" == 1 ]; then

if [ -n "${USE_MEMORY}" ]; then _ibx_prep="$_ibx --use-memory=$USE_MEMORY"; fi

if [ "$status" != 1 ]; then
   _start_prepare_date=`date`
   _s_inf "INFO: Apply log started: ${_start_prepare_date}"

   if [ "${BKP_TYPE}" == "incr" ];
   then
      if [ ! -n "$_incr_base" ];
      then
         _d_inf "ERROR: No valid base backup found!";
      fi

      _incr_base=P_${_incr_base}

      if [ ! -d "${WORK_DIR}/bkps/${_incr_base}" ];
      then
         _d_inf "ERROR: Base backup ${WORK_DIR}/bkps/${_incr_base} does not exist.";
      fi
      _ibx_prep="${_ibx_prep} --apply-log --redo-only ${WORK_DIR}/bkps/${_incr_base} --incremental-dir ${_this_bkp}"
      _echo "INFO: Preparing incremental backup with ${_ibx_prep}"
      _last_full_prep=${WORK_DIR}/bkps/${_incr_base}/
   else
      _apply_to="${WORK_DIR}/bkps/P_${CURDATE}"
      # Check to make sure we have enough disk space to make a copy
      _bu_size=$(_du_r $_this_bkp)
      _du_left=$(_df $WORK_DIR)
      if [ "${_bu_size}" -gt "${_du_left}" ]; then
         _d_inf "ERROR: Apply to copy was specified, however there is not \
            enough disk space left on device.";
      else
         cp -r ${_this_bkp} ${_apply_to}
      fi

      _ibx_prep="${_ibx_prep} --apply-log --redo-only ${_apply_to}"
      _echo "INFO: Preparing base backup with ${_ibx_prep}"
      _last_full_prep=${WORK_DIR}/bkps/P_${CURDATE}/
   fi

   $_ibx_prep
   RETVAR=$?
fi

_end_prepare_date=`date`
echo
_s_inf "INFO: Apply log finished: ${_end_prepare_date}"
echo

# Check the exit status from innobackupex, but dont exit right
# away if it failed
if [ "$RETVAR" -gt 0 ]; then
   _s_inf "ERROR: non-zero exit status of xtrabackup during --apply-log. \
      Something may have failed! Please prepare, I have not deleted the \
      new backup directory.";
elif [ "x$STOR_CMP" != "x1" ]; then
    rm -rf ${_this_bkp}
fi

# End, whether apply log is enabled
fi

_started_at="STR_TO_DATE('${CURDATE}','%Y-%m-%d_%H_%i_%s')"
if [ "$APPLY_LOG" == 1 ]; then
   _ends_at=`date -d "${_end_prepare_date}" "+%Y-%m-%d %H:%M:%S"`
else
   _ends_at=`date -d "${_end_backup_date}" "+%Y-%m-%d %H:%M:%S"`
fi
if [ "${BKP_TYPE}" == "incr" ]; then
   _incr_basedir="STR_TO_DATE('${_incr_basedir}','%Y-%m-%d_%H_%i_%s')"
else
   _incr_basedir="NULL"
fi
[ -d "${_this_bkp}" ] && _bu_size=$(_du_h ${_this_bkp}) || _bu_size=$(_du_h ${_this_bkp_stored})
_du_left=$(_df_h $WORK_DIR)

_sql_save_bkp "${_started_at}" "${_ends_at}" "${_bu_size}" \
   "${STOR_DIR}/bkps/${CURDATE}" "${_incr_basedir}" \
   "${_week_no}" "${_incr_baseid}"

_echo "INFO: Cleaning up previous backup files:"
# Depending on how many sets to keep, we query the backups table.
# Find the ids of base backups first.
_prune_base=$(_sql_prune_base)
if [ -n "$_prune_base" ]; then
   _prune_list=$(_sql_prune_list $_prune_base)
   if [ -n "$_prune_list" ]; then
      _echo "INFO: Deleting backups: ${_prune_list}"
      _sql_prune_rows $_prune_base
      cd $STOR_DIR/bkps && rm -rf $_prune_list
   fi
fi
_echo " ... done"
echo

_end_backup_date=`date`
echo
_s_inf "INFO: Backup job finished: ${_end_backup_date}"
echo

_s_inf "INFO: Backup size: ${_bu_size}"
_s_inf "INFO: Remaining space available on backup device: ${_du_left}"
_s_inf "INFO: Logfile: ${LOG_FILE}"
[ "x$APPLY_LOG" == "x1" ] && \
   _s_inf "INFO: Last full backup fully prepared (including incrementals): ${_last_full_prep}"
cp ${INF_FILE_WORK} ${INF_FILE_STOR}
echo

rm -rf /tmp/xbackup.lock

exit 0
