#!/bin/sh

CONFIG=passwall
LOG_FILE=/tmp/log/$CONFIG.log
LOCK_FILE_DIR=/tmp/lock
LOG_EVENT_FILTER=
LOG_EVENT_CMD=
flag=0

echolog() {
	local d="$(date "+%Y-%m-%d %H:%M:%S")"
	local c="$1"
	echo -e "$d: $c" >> $LOG_FILE
	[ -n "$LOG_EVENT_CMD" ] && [ -n "$(echo -n $c |grep -E "$LOG_EVENT_FILTER")" ] && {
		$(echo -n $LOG_EVENT_CMD |sed "s/%s/$c/g")
	}
}

config_n_get() {
	local ret=$(uci -q get "${CONFIG}.${1}.${2}" 2>/dev/null)
	echo "${ret:=$3}"
}

test_url() {
	local url=$1
	local try=1
	[ -n "$2" ] && try=$2
	local timeout=2
	[ -n "$3" ] && timeout=$3
	local extra_params=$4
	if /usr/bin/curl --help all | grep -q "\-\-retry-all-errors"; then
		extra_params="--retry-all-errors ${extra_params}"
	fi
	status=$(/usr/bin/curl -I -o /dev/null -skL ${extra_params} --connect-timeout ${timeout} --retry ${try} -w %{http_code} "$url")
	case "$status" in
		204)
			status=200
		;;
	esac
	echo $status
}

test_proxy() {
	result=0
	status=$(test_url "${probe_url}" ${retry_num} ${connect_timeout} "-x socks5h://127.0.0.1:${socks_port}")
	if [ "$status" = "200" ]; then
		result=0
	else
		status2=$(test_url "https://www.baidu.com" ${retry_num} ${connect_timeout})
		if [ "$status2" = "200" ]; then
			result=1
		else
			result=2
			ping -c 3 -W 1 223.5.5.5 > /dev/null 2>&1
			[ $? -eq 0 ] && {
				result=1
			}
		fi
	fi
	echo $result
}

test_node() {
	local node_id=$1
	local _type=$(echo $(config_n_get ${node_id} type) | tr 'A-Z' 'a-z')
	[ -n "${_type}" ] && {
		local _tmp_port=$(/usr/share/${CONFIG}/app.sh get_new_port 61080 tcp,udp)
		/usr/share/${CONFIG}/app.sh run_socks flag="test_node_${node_id}" node=${node_id} bind=127.0.0.1 socks_port=${_tmp_port} config_file=test_node_${node_id}.json
		local curlx="socks5h://127.0.0.1:${_tmp_port}"
		sleep 1s
		_proxy_status=$(test_url "${probe_url}" ${retry_num} ${connect_timeout} "-x $curlx")
		# 结束 SS 插件进程
		local pid_file="/tmp/etc/${CONFIG}/test_node_${node_id}_plugin.pid"
		[ -s "$pid_file" ] && kill -9 "$(head -n 1 "$pid_file")" >/dev/null 2>&1
		pgrep -af "test_node_${node_id}" | awk '! /socks_auto_switch\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
		rm -rf /tmp/etc/${CONFIG}/test_node_${node_id}*.*
		if [ "${_proxy_status}" -eq 200 ]; then
			return 0
		fi
	}
	return 1
}

test_auto_switch() {
	flag=$(expr $flag + 1)
	local b_nodes=$1
	local now_node=$2
	[ -z "$now_node" ] && {
		if [ -n "$(/usr/share/${CONFIG}/app.sh get_cache_var "socks_${id}")" ]; then
			now_node=$(/usr/share/${CONFIG}/app.sh get_cache_var "socks_${id}")
		else
			#echolog "自动切换检测：未知错误"
			return 1
		fi
	}

	[ $flag -le 1 ] && {
		main_node=$now_node
	}

	status=$(test_proxy)
	if [ "$status" == 2 ]; then
		echolog "自动切换检测：无法连接到网络，请检查网络是否正常！"
		return 2
	fi

	#检测主节点是否能使用
	if [ "$restore_switch" == "1" ] && [ -n "$main_node" ] && [ "$now_node" != "$main_node" ]; then
		test_node ${main_node}
		[ $? -eq 0 ] && {
			#主节点正常，切换到主节点
			echolog "自动切换检测：${id}主节点【$(config_n_get $main_node type)：[$(config_n_get $main_node remarks)]】正常，切换到主节点！"
			/usr/share/${CONFIG}/app.sh socks_node_switch flag=${id} new_node=${main_node}
			[ $? -eq 0 ] && {
				echolog "自动切换检测：${id}节点切换完毕！"
			}
			return 0
		}
	fi

	if [ "$status" == 0 ]; then
		#echolog "自动切换检测：${id}【$(config_n_get $now_node type)：[$(config_n_get $now_node remarks)]】正常。"
		return 0
	elif [ "$status" == 1 ]; then
		echolog "自动切换检测：${id}【$(config_n_get $now_node type)：[$(config_n_get $now_node remarks)]】异常，切换到下一个备用节点检测！"
		local new_node
		in_backup_nodes=$(echo $b_nodes | grep $now_node)
		# 判断当前节点是否存在于备用节点列表里
		if [ -z "$in_backup_nodes" ]; then
			# 如果不存在，设置第一个节点为新的节点
			new_node=$(echo $b_nodes | awk -F ' ' '{print $1}')
		else
			# 如果存在，设置下一个备用节点为新的节点
			#local count=$(expr $(echo $b_nodes | grep -o ' ' | wc -l) + 1)
			local next_node=$(echo $b_nodes | awk -F "$now_node" '{print $2}' | awk -F " " '{print $1}')
			if [ -z "$next_node" ]; then
				new_node=$(echo $b_nodes | awk -F ' ' '{print $1}')
			else
				new_node=$next_node
			fi
		fi
		test_node ${new_node}
		if [ $? -eq 0 ]; then
			[ "$restore_switch" == "0" ] && {
				uci set $CONFIG.${id}.node=$new_node
				[ -z "$(echo $b_nodes | grep $main_node)" ] && uci add_list $CONFIG.${id}.autoswitch_backup_node=$main_node
				uci commit $CONFIG
			}
			echolog "自动切换检测：${id}【$(config_n_get $new_node type)：[$(config_n_get $new_node remarks)]】正常，切换到此节点！"
			/usr/share/${CONFIG}/app.sh socks_node_switch flag=${id} new_node=${new_node}
			[ $? -eq 0 ] && {
				echolog "自动切换检测：${id}节点切换完毕！"
			}
			return 0
		else
			test_auto_switch "${b_nodes}" ${new_node}
		fi
	fi
}

start() {
	id=$1
	LOCK_FILE=${LOCK_FILE_DIR}/${CONFIG}_socks_auto_switch_${id}.lock
	LOG_EVENT_FILTER=$(uci -q get "${CONFIG}.global[0].log_event_filter" 2>/dev/null)
	LOG_EVENT_CMD=$(uci -q get "${CONFIG}.global[0].log_event_cmd" 2>/dev/null)
	main_node=$(config_n_get $id node)
	socks_port=$(config_n_get $id port 0)
	delay=$(config_n_get $id autoswitch_testing_time 30)
	sleep 5s
	connect_timeout=$(config_n_get $id autoswitch_connect_timeout 3)
	retry_num=$(config_n_get $id autoswitch_retry_num 1)
	restore_switch=$(config_n_get $id autoswitch_restore_switch 0)
	probe_url=$(config_n_get $id autoswitch_probe_url "https://www.google.com/generate_204")
	backup_node=$(config_n_get $id autoswitch_backup_node)
	while [ -n "$backup_node" ]; do
		[ -f "$LOCK_FILE" ] && {
			sleep 6s
			continue
		}
		pgrep -af "${CONFIG}/" | awk '/app\.sh.*(start|stop)/ || /nftables\.sh/ || /iptables\.sh/ { found = 1 } END { exit !found }' && {
			# 特定任务执行中不检测
			sleep 6s
			continue
		}
		touch $LOCK_FILE
		backup_node=$(echo $backup_node | tr -s ' ' '\n' | uniq | tr -s '\n' ' ')
		test_auto_switch "$backup_node"
		rm -f $LOCK_FILE
		sleep ${delay}
	done
}

start $@

