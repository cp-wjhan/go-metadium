#!/bin/bash

META_DIR=${META_DIR:-/opt}

function get_script_dir ()
{
    OPWD=$(pwd)
    echo $(cd $(dirname ${BASH_SOURCE[0]}) &> /dev/null && pwd)
    cd "$OPWD"
}

function get_data_dir ()
{
    if [ ! "$1" = "" ]; then
	if [ -x "$1/bin/gmet" ]; then
	    echo $1
        else
	    d=${META_DIR}/$1
	    if [ -x "$d/bin/gmet" ]; then
		echo $d
	    fi
	fi
    else
	echo $(dirname $(get_script_dir))
    fi
}

# void init(String node, String config_json)
function init ()
{
    NODE="$1"
    CONFIG="$2"

    if [ ! -f "$CONFIG" ]; then
	echo "Cannot find config file: $2"
	return 1
    fi

    d=$(get_data_dir "${NODE}")
    if [ -x "$d/bin/gmet" ]; then
    GMET="$d/bin/gmet"
    else
	echo "Cannot find gmet"
	return 1
    fi

    if [ ! -f "${d}/conf/genesis-template.json" ]; then
	echo "Cannot find template files."
	return 1
    fi

    echo "wiping out data..."
    wipe $NODE

    [ -d "$d/geth" ] || mkdir -p "$d/geth"
    [ -d "$d/logs" ] || mkdir -p "$d/logs"

    ${GMET} metadium genesis --data "$CONFIG" --genesis "$d/conf/genesis-template.json" --out "$d/genesis.json"
    [ $? = 0 ] || return $?

    echo "PORT=8588
DISCOVER=0" > $d/.rc
    ${GMET} --datadir $d init $d/genesis.json
    # echo "Generating dags for epoch 0 and 1..."
    # ${GMET} makedag 0     $d/.ethash &
    # ${GMET} makedag 30000 $d/.ethash &
    wait
}

# void init_gov(String node, String config_json, String account_file, bool doInitOnce)
# account_file can be
#   1. keystore file: "<path>"
#   2. nano ledger: "ledger:"
#   3. trezor: "trezor:"
function init_gov ()
{
    NODE="$1"
    CONFIG="$2"
    ACCT="$3"
    [ "$4" = "0" ] && INIT_ONCE=false || INIT_ONCE=true

    if [ ! -f "$CONFIG" ]; then
	echo "Cannot find config file: $2"
	return 1
    fi

    d=$(get_data_dir "${NODE}")
    if [ -x "$d/bin/gmet" ]; then
	GMET="$d/bin/gmet"
    else
	echo "Cannot find gmet"
	return 1
    fi

    if [ ! -f "${d}/conf/MetadiumGovernance.js" ]; then
	echo "Cannot find ${d}/conf/MetadiumGovernance.js"
	return 1
    fi

    PORT=$(grep PORT ${d}/.rc | sed -e 's/PORT=//')
    [ "$PORT" = "" ] && PORT=8588

    exec ${GMET} attach http://localhost:${PORT} --preload "$d/conf/MetadiumGovernance.js,$d/conf/deploy-governance.js" --exec 'GovernanceDeployer.deploy("'${ACCT}'", "", "'${CONFIG}'", '${INIT_ONCE}')'
}

function wipe ()
{
    d=$(get_data_dir "$1")
    if [ ! -x "$d/bin/gmet" ]; then
	echo "Is '$1' metadium data directory?"
	return
    fi

    cd $d
    /bin/rm -rf geth/LOCK geth/chaindata geth/ethash geth/lightchaindata \
	geth/transactions.rlp geth/nodes geth/triecache gmet.ipc logs/* etcd
}

function clean ()
{
    d=$(get_data_dir "$1")
    if [ -x "$d/bin/gmet" ]; then
	GMET="$d/bin/gmet"
    else
	echo "Cannot find gmet"
	return
    fi

    cd $d
    $GMET --datadir ${PWD} removedb
}

function start ()
{
    d=$(get_data_dir "$1")
    if [ -x "$d/bin/gmet" ]; then
	GMET="$d/bin/gmet"
    else
	echo "Cannot find gmet"
	return
    fi

    [ -f "$d/.rc" ] && source "$d/.rc"
    [ "$COINBASE" = "" ] && COINBASE="" || COINBASE="--miner.etherbase $COINBASE"

    RPCOPT="--http --http.addr 0.0.0.0"
    [ "$PORT" = "" ] || RPCOPT="${RPCOPT} --http.port ${PORT}"
    RPCOPT="${RPCOPT} --ws --ws.addr 0.0.0.0"
    [ "$PORT" = "" ] || RPCOPT="${RPCOPT} --ws.port $((${PORT}+10))"
    [ "$NONCE_LIMIT" = "" ] || NONCE_LIMIT="--noncelimit $NONCE_LIMIT"
    [ "$BOOT_NODES" = "" ] || BOOT_NODES="--bootnodes $BOOT_NODES"
    [ "$TESTNET" = "1" ] && TESTNET=--metadium-testnet
    if [ "$DISCOVER" = "0" ]; then
	DISCOVER=--nodiscover
    else
	DISCOVER=
    fi
    case $SYNC_MODE in
    "full")
	SYNC_MODE="--syncmode full";;
    "fast")
	SYNC_MODE="--syncmode fast";;
    "snap")
	SYNC_MODE="--syncmode snap";;
    *)
	SYNC_MODE="--syncmode full --gcmode archive";;
    esac

    OPTS="$COINBASE $DISCOVER $RPCOPT $BOOT_NODES $NONCE_LIMIT $TESTNET $SYNC_MODE ${GMET_OPTS}"
    [ "$PORT" = "" ] || OPTS="${OPTS} --port $(($PORT + 1))"
    [ "$HUB" = "" ] || OPTS="${OPTS} --hub ${HUB}"
    [ "$MAX_TXS_PER_BLOCK" = "" ] || OPTS="${OPTS} --maxtxsperblock ${MAX_TXS_PER_BLOCK}"

    [ -d "$d/logs" ] || mkdir -p $d/logs

    cd $d
    if [ ! "$2" = "inner" ]; then
	$GMET --datadir ${PWD} --metrics $OPTS 2>&1 |   \
	    ${d}/bin/logrot ${d}/logs/log 10M 5 &
    else
	if [ -x "$d/bin/logrot" ]; then
	    exec > >($d/bin/logrot $d/logs/log 10M 5)
	    exec 2>&1
	fi
	exec $GMET --datadir ${PWD} --metrics $OPTS
    fi
}

function get_gmet_pids ()
{
    ps axww | grep -v grep | grep "gmet.*datadir.*${1}" | awk '{print $1}'
}

function do_nodes ()
{
    LHN=$(hostname)
    CMD=${1/-nodes/}
    shift
    while [ ! "$1" = "" -a ! "$2" = "" ]; do
	if [ "$1" = "$LHN" -o "$1" = "${LHN/.*/}" ]; then
	    $0 ${CMD} $2
	else
	    ssh -f $1 ${META_DIR}/$2/bin/gmet.sh ${CMD} $2
	fi
	shift
	shift
    done
}

function usage ()
{
    echo "Usage: `basename $0` [init <node> <config.json> |
	init-gov <node> <config.json> <account-file> <do-init-once>|
	clean [<node>] | wipe [<node>] | console [<node>] |
	[re]start [<node>] | stop [<node>] | [re]start-nodes | stop-nodes]

*-nodes uses NODES environment variable: [<host> <dir>]+
"
}

case "$1" in
"init")
    if [ $# -lt 3 ]; then
	usage;
    else
	init "$2" "$3"
    fi
    ;;

"init-gov")
    if [ $# -lt 4 ]; then
	usage;
    else
	init_gov "$2" "$3" "$4" "$5"
    fi
    ;;

"wipe")
    wipe $2
    ;;

"clean")
    clean $2
    ;;

"stop")
    echo -n "stopping..."
    dir=$(get_data_dir $2)
    PIDS=$(get_gmet_pids ${dir})
    if [ ! "$PIDS" = "" ]; then
        # check if we're the miner or leader
        CMD='
function check_if_mining() {
  for (var i = 0; i < 15; i++) {
    try {
      var token = debug.etcdGet("token")
      eval("token = " + token)
      // console.log("miner -> " + token.miner)
      if (token.miner != admin.metadiumInfo.self.name) {
        break
      } else {
        console.log("we are the miner, sleeping...")
        admin.sleep(0.25)
      }
    } catch {
      admin.sleep(0.25)
    }
  }
}
if (admin.metadiumInfo != null && admin.metadiumInfo.self != null) {
  check_if_mining()
  if (admin.metadiumInfo.etcd.leader.name == admin.metadiumInfo.self.name) {
    var nodes = admin.metadiumNodes("", 0)
    for (var n of nodes) {
      if (admin.metadiumInfo.etcd.leader.name != admin.metadiumInfo.self.name) {
        break
      }
      if (n.status == "up" && n.name != admin.metadiumInfo.self.name) {
        console.log("moving leader to " + n.name)
        admin.etcdMoveLeader(n.name)
      }
    }
  }
  check_if_mining()
}'
	${dir}/bin/gmet attach ipc:${dir}/gmet.ipc --exec "$CMD" | grep -v "undefined"
	echo $PIDS | xargs -L1 kill
    fi
    for i in {1..200}; do
	PIDS=$(get_gmet_pids ${dir})
	[ "$PIDS" = "" ] && break
	echo -n "."
	sleep 1
    done
    PIDS=$(get_gmet_pids ${dir})
    if [ ! "$PIDS" = "" ]; then
	echo $PIDS | xargs -L1 kill -9
    fi
    # wait until geth/chaindata is free
    for i in {1..200}; do
	lsof ${dir}/geth/chaindata/LOG 2>&1 | grep -q gmet > /dev/null 2>&1 || break
	sleep 1
    done
    echo "done."
    ;;

"start")
    start $2
    ;;

"start-inner")
    if [ "$2" = "" ]; then
	usage;
    else
	start $2 inner
    fi
    ;;

"restart")
    $0 stop $2
    start $2
    ;;

"start-nodes"|"restart-nodes"|"stop-nodes")
    if [ "${NODES}" = "" ]; then
	echo "NODES is not defined"
    fi
    do_nodes $1 ${NODES}
    ;;

"console")
    d=$(get_data_dir "$2")
    if [ ! -d $d ]; then
	usage; exit;
    fi
    RCJS=
    if [ -f "$d/rc.js" ]; then
	RCJS="--preload $d/rc.js"
    fi
    exec ${d}/bin/gmet ${RCJS} attach ipc:${d}/gmet.ipc
    ;;

*)
    usage;
    ;;
esac

# EOF
