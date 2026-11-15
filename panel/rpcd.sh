#!/bin/sh
# SkyrimVPN — серверная часть веб-панели (rpcd-плагин, ubus-объект «skyrimvpn»).
# Её вызывают страница http://<роутер>/skyrim и пункт «SkyrimVPN» в меню OpenWrt.
# Вся логика берётся из /usr/bin/skyrim, чтобы панель и консоль работали одинаково.

. /usr/share/libubox/jshn.sh

LOCK=/tmp/skyrim-task.lock   # папка-замок: пока она есть, роутер занят командой
TASK_LOG=/tmp/skyrim-task.log
CFG=passwall2

lib() { SKYRIM_LIB=1 . /usr/bin/skyrim; detect_system >/dev/null 2>&1; }

valid_id() { case "$1" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac; return 0; }

# Занят ли роутер (командой из панели, консоли или «Сторожем»).
# Замок без живого процесса (сбой, перезагрузка) снимается сам — как lock_busy в skyrim.
busy() {
	[ -d "$LOCK" ] || return 1
	local p; p=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$p" ]; then kill -0 "$p" 2>/dev/null && return 0
	elif [ $(( $(date +%s) - $(date -r "$LOCK" +%s 2>/dev/null || date +%s) )) -lt 60 ]; then return 0; fi
	rm -rf "$LOCK"
	return 1
}

# Запустить задачу в фоне: $1 — подпись для страницы, $2 — функция, $3 — аргумент.
# mkdir атомарен: две команды одновременно не стартуют.
run_bg() {
	busy && return 1
	mkdir "$LOCK" 2>/dev/null || return 1
	echo "$1" >"$LOCK/label"
	(
		lib
		"$2" "$3"
		rm -rf "$LOCK"
	) </dev/null >"$TASK_LOG" 2>&1 &
	echo $! >"$LOCK/pid"
	return 0
}

task_server() {
	setup_routing "$1"; vpn_restart
	if verify; then event info "Сервер выбран вручную: «$(node_name "$1")»."
	else event warn "Выбран сервер «$(node_name "$1")», но он не отвечает."; fi
}
task_toggle() {
	if [ "$1" = "on" ]; then
		uci set $CFG.@global[0].enabled=1; uci commit $CFG; vpn_restart
		verify && event info "VPN включён." || event warn "VPN включён, но подключение не проходит."
	else
		uci set $CFG.@global[0].enabled=0; uci commit $CFG; /etc/init.d/passwall2 stop
		ok "VPN выключен. Интернет идёт напрямую."; event info "VPN выключен вручную."
	fi
}
task_update() {
	update_subscription || { event err "Подписка не обновилась. Проверьте срок в боте."; return; }
	event info "Подписка обновлена: $(node_ids | wc -l) серверов."
	local cur; cur=$(uci -q get $CFG.$SHUNT_ID.default_node)
	if [ -z "$cur" ] || [ -z "$(node_name "$cur")" ]; then task_auto
	elif [ "$(uci -q get $CFG.@global[0].enabled)" = "1" ]; then vpn_restart; verify
	fi
}
task_set_sub() { save_subscription "$1"; task_update; }
task_auto() {
	local best; best=$(auto_pick)
	if [ -n "$best" ]; then
		setup_routing "$best"; vpn_restart; verify
		event info "Подобран самый быстрый сервер: «$(node_name "$best")»."
	else
		err "Ни один сервер не ответил. Проверьте подписку или выберите сервер вручную."
	fi
}

reply() {   # $1 — код run_bg
	json_init
	if [ "$1" = "0" ]; then json_add_boolean ok 1
	else json_add_boolean ok 0; json_add_string error "Подождите: роутер ещё выполняет предыдущую команду."; fi
	json_dump
}
reply_err() { json_init; json_add_boolean ok 0; json_add_string error "$1"; json_dump; }

m_status() {
	json_init
	if [ ! -f /usr/share/passwall2/subscribe.lua ] || [ ! -x /usr/bin/skyrim ]; then
		json_add_boolean installed 0; json_dump; return
	fi
	lib
	local node; node=$(uci -q get $CFG.$SHUNT_ID.default_node)
	json_add_boolean installed 1
	json_add_string version "$VERSION"
	json_add_boolean enabled "$([ "$(uci -q get $CFG.@global[0].enabled)" = "1" ] && echo 1 || echo 0)"
	json_add_boolean running "$(vpn_running && echo 1 || echo 0)"
	json_add_string server_id "$node"
	json_add_string server_name "$( [ -n "$node" ] && node_name "$node")"
	json_add_int servers "$(node_ids | wc -l)"
	json_add_boolean has_sub "$([ -n "$(current_sub_url)" ] && echo 1 || echo 0)"
	json_add_string expire "$(uci -q get $CFG.$SUB_ID.expired_date)"
	json_add_string traffic "$(uci -q get $CFG.$SUB_ID.rem_traffic)"
	json_add_int free_mb "$(( $(free_kb) / 1024 ))"
	json_add_boolean watchdog "$([ "$(setting watchdog)" = "0" ] && echo 0 || echo 1)"
	json_add_boolean autoswitch "$([ "$(setting autoswitch)" = "0" ] && echo 0 || echo 1)"
	json_add_string sub_hours "$(setting sub_hours)"
	if busy; then json_add_string busy "$(cat "$LOCK/label" 2>/dev/null)"
	# PassWall сам запускается: после включения роутера он ждёт ~1 минуту
	# (пока нет /var/lock/passwall2_ready.lock), либо идёт его перезапуск
	elif [ "$(uci -q get $CFG.@global[0].enabled)" = "1" ] && ! vpn_running && { ps w | grep -q "[a]pp.sh start" || \
		{ [ ! -f /var/lock/passwall2_ready.lock ] && [ "$(cut -d. -f1 /proc/uptime)" -lt 300 ]; }; }; then
		json_add_string busy "VPN запускается…"
	else json_add_string busy ""; fi
	# итог последней команды: ошибка, если была, иначе главная строка успеха
	local res; res=$(sed 's/\x1b\[[0-9;]*m//g' "$TASK_LOG" 2>/dev/null)
	json_add_string last "$( { echo "$res" | grep '^✖' || echo "$res" | grep -E '^✔ (VPN|Загружено|Выбран)' || echo "$res" | grep '^✔'; } | tail -1)"
	json_dump
}

m_servers() {
	lib
	json_init
	json_add_array servers
	local id proto tr reality name tab
	tab=$(printf '\t')
	node_table >/tmp/skyrim-nodes.tsv
	while IFS="$tab" read -r id proto tr reality name; do
		[ "$proto" = "-" ] && proto=""; [ "$tr" = "-" ] && tr=""; [ "$name" = "-" ] && name=""
		json_add_object
		json_add_string id "$id"
		json_add_string name "$name"
		json_add_string protocol "$proto"
		json_add_string transport "$tr"
		json_add_boolean reality "$([ "$reality" = "1" ] && echo 1 || echo 0)"
		json_close_object
	done </tmp/skyrim-nodes.tsv
	rm -f /tmp/skyrim-nodes.tsv
	json_close_array
	json_dump
}

m_ip() {
	json_init
	json_add_string ip "$(curl -s -m 8 https://ifconfig.co/ip 2>/dev/null | grep -E '^[0-9a-fA-F.:]+$')"
	json_add_string country "$(curl -s -m 8 https://ifconfig.co/country 2>/dev/null | grep -E '^[A-Za-z .-]{2,40}$')"
	json_dump
}

m_test() {
	json_init
	if valid_id "$1"; then lib; json_add_string ms "$(test_node "$1")"
	else json_add_string ms ""; fi
	json_dump
}

# Журнал событий «Сторожа» (новые сверху).
m_events() {
	json_init
	json_add_array events
	local t l m
	# не через «| while»: цикл в конвейере идёт в отдельном процессе и JSON бы потерялся
	tail -30 /tmp/skyrim-events.log 2>/dev/null | sed '1!G;h;$!d' >/tmp/skyrim-ev.tmp
	while IFS='|' read -r t l m; do
		[ -n "$t" ] || continue
		json_add_object
		json_add_int t "$t"
		json_add_string level "$l"
		json_add_string text "$m"
		json_close_object
	done </tmp/skyrim-ev.tmp
	rm -f /tmp/skyrim-ev.tmp
	json_close_array
	json_dump
}

# Включить/выключить «Сторож» и автопереключение сервера.
m_settings() {
	lib
	settings_init
	case "$1" in 0|1) uci set skyrim.main.watchdog="$1" ;; esac
	case "$2" in 0|1) uci set skyrim.main.autoswitch="$2" ;; esac
	uci commit skyrim
	json_init; json_add_boolean ok 1; json_dump
}

m_report() {
	lib
	json_init
	json_add_string text "$(do_report 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
	json_dump
}

case "$1" in
	list)
		echo '{"status":{},"servers":{},"ip":{},"report":{},"events":{},"settings":{"watchdog":true,"autoswitch":true},"test":{"id":"str"},"set_server":{"id":"str"},"toggle":{"on":true},"update_sub":{},"set_sub":{"url":"str"},"auto":{}}'
		;;
	call)
		read -r input
		[ -n "$input" ] || input='{}'
		json_load "$input"
		case "$2" in
			status)  m_status ;;
			servers) m_servers ;;
			ip)      m_ip ;;
			report)  m_report ;;
			events)  m_events ;;
			settings)
				json_get_var wd watchdog; json_get_var as autoswitch
				m_settings "$wd" "$as"
				;;
			test)    json_get_var id id; m_test "$id" ;;
			set_server)
				json_get_var id id
				if valid_id "$id"; then run_bg "Переключаю сервер…" task_server "$id"; reply $?
				else reply_err "Неверный сервер."; fi
				;;
			toggle)
				json_get_var on on
				if [ "$on" = "1" ]; then run_bg "Включаю VPN…" task_toggle on; else run_bg "Выключаю VPN…" task_toggle off; fi
				reply $?
				;;
			update_sub) run_bg "Обновляю подписку…" task_update ""; reply $? ;;
			auto)       run_bg "Ищу самый быстрый сервер…" task_auto ""; reply $? ;;
			set_sub)
				json_get_var url url
				lib
				if valid_url "$url"; then run_bg "Загружаю новую подписку…" task_set_sub "$url"; reply $?
				else reply_err "Это не похоже на ссылку на подписку. Скопируйте её в боте: «Подписка» → «Скопировать ссылку»."; fi
				;;
			*) reply_err "Неизвестная команда." ;;
		esac
		;;
esac
