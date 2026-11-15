#!/bin/sh
# ============================================================================
#  SkyrimVPN Router — установка SkyrimVPN на роутер с OpenWrt
#  https://github.com/Kochurin/SkyrimVPN-Router
#
#  Что делает:
#    1. Проверяет роутер (версия OpenWrt, память, место, интернет).
#    2. Ставит PassWall 2 + Xray из официального репозитория PassWall.
#    3. Загружает вашу подписку SkyrimVPN (VLESS/REALITY, Hysteria2).
#    4. Выбирает самый быстрый сервер и включает VPN для всей домашней сети.
#    5. Российские сайты (Госуслуги, банки, .ru/.рф) идут напрямую, без VPN.
#
#    6. «Сторож» каждые 3 минуты проверяет VPN и сам меняет упавший сервер.
#
#  Запуск:  sh <(wget -qO- https://kochurin.github.io/SkyrimVPN-Router/i)
#  Потом:   skyrim            (меню)    http://192.168.1.1/skyrim  (панель)
# ============================================================================

VERSION="1.2.1"
REPO="Kochurin/SkyrimVPN-Router"
RAW_BASES="https://raw.githubusercontent.com/$REPO/main https://cdn.jsdelivr.net/gh/$REPO@main https://kochurin.github.io/SkyrimVPN-Router"
PW_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
BOT="t.me/SkyrimVPN_bot"
SUPPORT="t.me/SkyrimVPN_help_bot"

CFG="passwall2"
SUB_ID="skyrim"          # секция подписки в /etc/config/passwall2
GROUP="SkyrimVPN"        # группа серверов из подписки
RULE_ID="SkyrimRU"       # правило «Россия напрямую»
SHUNT_ID="skyrim_shunt"  # узел-маршрутизатор: Россия напрямую, остальное в VPN
SEND_HWID="1"            # отправлять «отпечаток» роутера: он займёт одно место в лимите устройств

NEED_FREE_KB=40000       # меньше — ставить бессмысленно
WARN_FREE_KB=65000       # меньше — может не влезть, спрашиваем
NEED_RAM_KB=100000       # «128 МБ» роутер показывает как ~115 МБ
GOOD_RAM_KB=200000       # меньше — предупреждаем: рекомендуем 256 МБ

SET="skyrim"             # наши настройки: /etc/config/skyrim
EVENTS=/tmp/skyrim-events.log   # события «Сторожа» (в памяти, флеш не изнашиваем)
LOCK=/tmp/skyrim-task.lock      # «замок»: пока есть, роутер занят командой
AUTO="${AUTO:-0}"        # AUTO=1 — без вопросов (восстановление после перепрошивки)

# ---------------------------------------------------------------- оформление
if [ -t 1 ]; then
	R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;36m'; W='\033[1;37m'; N='\033[0m'
else
	R=''; G=''; Y=''; B=''; W=''; N=''
fi
say()  { printf "${B}▸${N} %s\n" "$*"; }
ok()   { printf "${G}✔${N} %s\n" "$*"; }
warn() { printf "${Y}!${N} %s\n" "$*"; }
err()  { printf "${R}✖ %s${N}\n" "$*"; }
die()  { err "$*"; printf "  Поддержка: %s\n" "$SUPPORT"; exit 1; }
ask()  { printf "${W}%s${N} " "$1"; read -r ANSWER </dev/tty; }
yes_no() {
	[ "$AUTO" = "1" ] && return 0
	ask "$1 [y/N]:"; case "$ANSWER" in y|Y|д|Д|yes|да) return 0 ;; esac; return 1
}
pause() { printf "\nНажмите Enter, чтобы продолжить…"; read -r _ </dev/tty; }

banner() {
	printf "\n${W}  SkyrimVPN Router${N} v%s — VPN для всей домашней сети\n" "$VERSION"
	printf "  Бот: %s   Поддержка: %s\n\n" "$BOT" "$SUPPORT"
}

# ---------------------------------------------------------------- система
detect_system() {
	[ "$(id -u)" = "0" ] || die "Запустите скрипт от root (зайдите на роутер как root)."
	[ -f /etc/openwrt_release ] || die "Это не OpenWrt. Скрипт работает только на роутерах с OpenWrt."
	. /etc/openwrt_release
	RELEASE="$DISTRIB_RELEASE"
	ARCH="$DISTRIB_ARCH"
	case "$RELEASE" in
		SNAPSHOT*|*-SNAPSHOT) die "Сборки SNAPSHOT не поддерживаются. Поставьте стабильную версию OpenWrt 24.10 или новее." ;;
	esac
	BRANCH="${RELEASE%.*}"   # 24.10.8 -> 24.10
	case "$BRANCH" in
		23.05|24.10|25.12) ;;
		*) die "OpenWrt $RELEASE не поддерживается. Нужна версия 23.05, 24.10 или 25.12." ;;
	esac
	if command -v apk >/dev/null 2>&1; then PKG="apk"; else PKG="opkg"; fi
}

pkg_update() {
	if [ "$PKG" = "apk" ]; then apk update >>/tmp/skyrim-pkg.log 2>&1
	else opkg update >>/tmp/skyrim-pkg.log 2>&1; fi
}
# Есть ли пакет в списке доступных (после обновления списка).
pkg_available() {
	if [ "$PKG" = "apk" ]; then apk list "$1" 2>/dev/null | grep -q "^$1-[0-9]"
	else opkg info "$1" 2>/dev/null | grep -q "^Version:"; fi
}
# Обновить список пакетов. SourceForge иногда не отдаёт файл с первого раза,
# а посторонний репозиторий пользователя может быть недоступен — поэтому
# успех = нужные нам пакеты доступны, и до 3 попыток.
pkg_update_retry() {
	local i
	: >/tmp/skyrim-pkg.log
	for i in 1 2 3; do
		pkg_update
		pkg_available luci-app-passwall2 && pkg_available xray-core && return 0
		[ $i -lt 3 ] && { warn "Сервер пакетов ответил не полностью, пробую ещё раз ($((i + 1))/3)…"; sleep 8; }
	done
	return 1
}
pkg_install() {
	if [ "$PKG" = "apk" ]; then apk add "$@" >>/tmp/skyrim-pkg.log 2>&1
	else opkg install "$@" >>/tmp/skyrim-pkg.log 2>&1; fi
}
pkg_remove() {
	if [ "$PKG" = "apk" ]; then apk del "$@" >>/tmp/skyrim-pkg.log 2>&1
	else opkg remove --autoremove "$@" >>/tmp/skyrim-pkg.log 2>&1; fi
}
pkg_has() {
	if [ "$PKG" = "apk" ]; then apk info -e "$1" >/dev/null 2>&1
	else opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; fi
}
is_installed() { pkg_has luci-app-passwall2 && pkg_has xray-core; }

free_kb() {
	local m=/
	grep -q " /overlay " /proc/mounts && m=/overlay
	df -k "$m" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_resources() {
	say "Проверяю роутер…"
	printf "  OpenWrt %s, архитектура %s, пакеты: %s\n" "$RELEASE" "$ARCH" "$PKG"

	local ram; ram=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	printf "  Оперативная память: %s МБ\n" "$((ram / 1024))"
	[ "$ram" -ge "$NEED_RAM_KB" ] || die "Мало оперативной памяти ($((ram / 1024)) МБ). Нужно от 128 МБ, лучше 256 МБ."
	if [ "$ram" -lt "$GOOD_RAM_KB" ]; then
		warn "Памяти немного ($((ram / 1024)) МБ). VPN будет работать, но при большой нагрузке может"
		warn "перезапускаться — «Сторож» поднимет его сам. Для стабильной работы лучше роутер с 256 МБ."
	fi

	is_installed && { ok "PassWall 2 уже установлен — пропускаю проверку места."; return; }
	local free; free=$(free_kb)
	printf "  Свободно на флеше: %s МБ\n" "$((free / 1024))"
	[ "$free" -ge "$NEED_FREE_KB" ] || die "Мало места на флеше ($((free / 1024)) МБ). Нужно хотя бы $((NEED_FREE_KB / 1024)) МБ, лучше $((WARN_FREE_KB / 1024))+."
	if [ "$free" -lt "$WARN_FREE_KB" ]; then
		warn "Места впритык: Xray и базы сайтов занимают 45–65 МБ. Установка может не поместиться."
		yes_no "Всё равно продолжить?" || exit 0
	fi
}

# Что именно не так с интернетом: net_diag печатает понятную причину.
#   ok — всё работает; dns — сеть есть, но не работают имена сайтов; down — интернета нет.
net_state() {
	# ping бывает закрыт у провайдера — тогда пробуем открыть ya.ru (он идёт мимо VPN)
	if ping -c1 -W3 77.88.8.8 >/dev/null 2>&1 || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 \
		|| curl -s -o /dev/null -m 8 https://ya.ru 2>/dev/null; then
		nslookup ya.ru >/dev/null 2>&1 || nslookup ya.ru 77.88.8.8 >/dev/null 2>&1 && echo ok || echo dns
	else
		echo down
	fi
}

# Интернет «напрямую», когда VPN не работает. Запущенный VPN с мёртвым сервером
# может мешать даже прямым соединениям, поэтому при неудаче проверяем ещё раз
# с остановленным PassWall. Результат — в $NET (ok|dns|down); PW_HELD=1 значит,
# что PassWall остановлен здесь и его нужно запустить (или перезапустить) снова.
net_state_direct() {
	PW_HELD=0
	NET=$(net_state)
	if [ "$NET" != "ok" ] && vpn_running; then
		/etc/init.d/passwall2 stop >/dev/null 2>&1
		PW_HELD=1
		sleep 2
		NET=$(net_state)
	fi
}
# Остановить VPN на время поиска сервера. Проверке серверов (test.sh) нужны
# служебные папки PassWall, которые он удаляет при остановке, — создаём их.
pw_pause() {
	/etc/init.d/passwall2 stop >/dev/null 2>&1
	local d; for d in acl bin iface route script_func process_list; do mkdir -p /tmp/etc/passwall2/$d; done
	mkdir -p /tmp/etc/passwall2_tmp
}
pw_resume() { [ "$PW_HELD" = "1" ] && /etc/init.d/passwall2 start >/dev/null 2>&1; PW_HELD=0; }

net_msg() {
	case "$1" in
		down) err "У роутера пропал интернет — VPN тут ни при чём. Проверьте кабель провайдера." ;;
		dns)  err "У роутера не работает DNS провайдера. Перезагрузите роутер." ;;
		*)    err "Сервер не отвечает. Выберите другой: в панели или skyrim → «Сменить сервер»." ;;
	esac
}

# Неверные часы на роутере ломают HTTPS («сертификат ещё не действителен»).
fix_clock() {
	[ "$(date +%Y)" -ge 2025 ] && return 0
	warn "На роутере неверные часы ($(date +%d.%m.%Y)). Синхронизирую время…"
	ntpd -q -n -p pool.ntp.org -p time.google.com >/dev/null 2>&1
	[ "$(date +%Y)" -ge 2025 ] && ok "Время исправлено: $(date '+%d.%m.%Y %H:%M')." \
		|| warn "Не удалось. Включите синхронизацию: System → System → «Sync with NTP-Server»."
}

check_internet() {
	say "Проверяю интернет на роутере…"
	fix_clock
	case "$(net_state)" in
		down) die "Роутер не выходит в интернет. Проверьте кабель провайдера и настройки WAN (Network → Interfaces)." ;;
		dns)  die "Интернет есть, но не открываются адреса сайтов (не работает DNS). Network → Interfaces → WAN → проверьте DNS-серверы." ;;
	esac
	wget -q -T 15 -O /dev/null "https://downloads.openwrt.org/" 2>/dev/null \
		|| die "Интернет есть, но сайт OpenWrt не открывается. Подождите пару минут и запустите снова."
	ok "Интернет есть."
}

# Ссылка на подписку: только https://..., без пробелов и символов, которые ломают команды.
valid_url() {
	case "$1" in
		https://?*|http://?*) ;;
		*) return 1 ;;
	esac
	case "$1" in
		*[[:space:]\"\'\`\$\\]*) return 1 ;;
	esac
	return 0
}

wait_dns() {
	local i=0
	while [ $i -lt 15 ]; do
		nslookup downloads.openwrt.org 127.0.0.1 >/dev/null 2>&1 && return 0
		sleep 2; i=$((i + 1))
	done
	return 1
}

# ---------------------------------------------------------------- установка
add_feeds() {
	say "Подключаю репозиторий PassWall…"
	local base="$PW_BASE/releases/packages-$BRANCH/$ARCH"
	if [ "$PKG" = "apk" ]; then
		mkdir -p /etc/apk/keys /etc/apk/repositories.d
		wget -q -T 20 -O /etc/apk/keys/passwall.pem "$PW_BASE/apk.pub" || die "Не удалось скачать ключ репозитория PassWall."
		local list=/etc/apk/repositories.d/customfeeds.list
		touch "$list"
		sed -i '/openwrt-passwall-build/d' "$list"
		for f in passwall_luci passwall_packages passwall2; do
			echo "$base/$f/packages.adb" >>"$list"
		done
	else
		wget -q -T 20 -O /tmp/passwall.pub "$PW_BASE/ipk.pub" || die "Не удалось скачать ключ репозитория PassWall."
		opkg-key add /tmp/passwall.pub >/dev/null 2>&1
		local list=/etc/opkg/customfeeds.conf
		touch "$list"
		sed -i '/openwrt-passwall-build/d' "$list"
		for f in passwall_luci passwall_packages passwall2; do
			echo "src/gz $f $base/$f" >>"$list"
		done
	fi
	say "Обновляю список пакетов (до минуты)…"
	pkg_update_retry || die "Сервер пакетов PassWall (SourceForge) не отвечает. Подождите 5–10 минут и запустите установку снова. Подробности: /tmp/skyrim-pkg.log"
	ok "Репозиторий подключён."
}

# dnsmasq-full нужен PassWall для DNS-правил. Сначала скачиваем, потом меняем:
# если удалить старый dnsmasq первым, роутер теряет DNS и не скачает новый.
swap_dnsmasq() {
	pkg_has dnsmasq-full && { ok "dnsmasq-full уже стоит."; return; }
	say "Меняю dnsmasq на dnsmasq-full…"
	cp /etc/config/dhcp /tmp/dhcp.skyrim.bak 2>/dev/null
	cd /tmp || return
	rm -f /tmp/dnsmasq-full*
	if [ "$PKG" = "apk" ]; then
		apk fetch dnsmasq-full >>/tmp/skyrim-pkg.log 2>&1 || { sleep 5; apk fetch dnsmasq-full >>/tmp/skyrim-pkg.log 2>&1; } \
			|| die "Не удалось скачать dnsmasq-full. Запустите установку ещё раз через пару минут."
		apk del dnsmasq >>/tmp/skyrim-pkg.log 2>&1
		apk add --allow-untrusted /tmp/dnsmasq-full*.apk >>/tmp/skyrim-pkg.log 2>&1
	else
		opkg download dnsmasq-full >>/tmp/skyrim-pkg.log 2>&1 || { sleep 5; opkg download dnsmasq-full >>/tmp/skyrim-pkg.log 2>&1; } \
			|| die "Не удалось скачать dnsmasq-full. Запустите установку ещё раз через пару минут."
		opkg remove dnsmasq >>/tmp/skyrim-pkg.log 2>&1
		opkg install /tmp/dnsmasq-full*.ipk >>/tmp/skyrim-pkg.log 2>&1
	fi
	[ -f /tmp/dhcp.skyrim.bak ] && [ ! -s /etc/config/dhcp ] && cp /tmp/dhcp.skyrim.bak /etc/config/dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	if ! pkg_has dnsmasq-full; then
		pkg_install dnsmasq
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		die "dnsmasq-full не установился, вернул обычный dnsmasq. Подробности: /tmp/skyrim-pkg.log"
	fi
	wait_dns || warn "DNS отвечает медленно, продолжаю."
	ok "dnsmasq-full установлен."
}

install_packages() {
	say "Ставлю PassWall 2 и Xray (2–5 минут, роутер может «задуматься»)…"
	pkg_install kmod-nft-socket kmod-nft-tproxy xray-core luci-app-passwall2
	if ! is_installed; then
		# обрыв скачивания — частая причина; если дело в месте, повтор не поможет
		if [ "$(free_kb)" -gt 20000 ]; then
			warn "Часть пакетов не скачалась, пробую ещё раз…"
			sleep 5
			pkg_install kmod-nft-socket kmod-nft-tproxy xray-core luci-app-passwall2
		fi
	fi
	pkg_install luci-i18n-passwall2-ru   # русский интерфейс; не страшно, если не встанет
	is_installed || die "PassWall 2 не установился (свободно $(( $(free_kb) / 1024 )) МБ). Если места мало — освободите его; иначе запустите установку ещё раз. Подробности: /tmp/skyrim-pkg.log"
	ok "PassWall 2 $(pw_version) и Xray установлены. Свободно на флеше: $(( $(free_kb) / 1024 )) МБ."
}

pw_version() {
	if [ "$PKG" = "apk" ]; then apk list -I luci-app-passwall2 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^luci-app-passwall2-//'
	else opkg list-installed luci-app-passwall2 | awk '{print $3}'; fi
}

# Скачать файл из репозитория (GitHub, при блокировке — зеркало jsDelivr).
# SKYRIM_SRC=/папка — взять файлы оттуда (для проверки до публикации).
fetch_file() {
	if [ -n "$SKYRIM_SRC" ] && [ -f "$SKYRIM_SRC/$1" ]; then cp "$SKYRIM_SRC/$1" "$2"; return; fi
	for b in $RAW_BASES; do
		wget -q -T 20 -O "$2.tmp" "$b/$1" 2>/dev/null && [ -s "$2.tmp" ] && { mv "$2.tmp" "$2"; return 0; }
	done
	rm -f "$2.tmp"
	return 1
}

install_self() {
	local dst=/usr/bin/skyrim
	if [ -f "$0" ] && [ "$0" != "$dst" ] && head -c 200 "$0" 2>/dev/null | grep -q "SkyrimVPN Router"; then
		cp "$0" "$dst"
	elif [ "$0" != "$dst" ] || [ "$1" = "force" ]; then
		fetch_file skyrim.sh "$dst.new" && grep -q "SkyrimVPN Router" "$dst.new" && mv "$dst.new" "$dst"
		rm -f "$dst.new"
	fi
	chmod +x "$dst" 2>/dev/null
}

# Веб-панель: пункт «SkyrimVPN» в панели роутера (http://192.168.1.1).
PANEL_FILES="panel/skyrimvpn.js:/www/luci-static/resources/view/skyrimvpn.js
panel/rpcd.sh:/usr/libexec/rpcd/skyrimvpn
panel/menu.json:/usr/share/luci/menu.d/luci-app-skyrimvpn.json
panel/acl.json:/usr/share/rpcd/acl.d/luci-app-skyrimvpn.json
panel/web/index.html:/www/skyrim/index.html
panel/web/app.js:/www/skyrim/app.js
panel/web/manifest.json:/www/skyrim/manifest.json
panel/web/favicon.png:/www/skyrim/favicon.png
panel/web/apple-touch-icon.png:/www/skyrim/apple-touch-icon.png
panel/web/icon-192.png:/www/skyrim/icon-192.png
panel/web/icon-512.png:/www/skyrim/icon-512.png
panel/logo.png:/www/skyrim/logo.png
panel/dragon.png:/www/skyrim/dragon.png"

install_panel() {
	say "Ставлю веб-панель SkyrimVPN…"
	rm -rf /www/luci-static/skyrimvpn   # старое место картинок (v1.0.0)
	mkdir -p /www/luci-static/resources/view /www/skyrim /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd
	local line failed=0 missing=0
	for line in $PANEL_FILES; do
		fetch_file "${line%%:*}" "${line#*:}" || failed=1
		[ -s "${line#*:}" ] || missing=1
	done
	if [ "$missing" = "1" ]; then
		warn "Панель не скачалась (GitHub недоступен). VPN работает, управлять можно командой skyrim;"
		warn "панель поставится позже командой: skyrim panel"
		return 1
	fi
	[ "$failed" = "1" ] && warn "GitHub недоступен — оставляю уже установленную панель."
	chmod +x /usr/libexec/rpcd/skyrimvpn
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
	/etc/init.d/rpcd restart >/dev/null 2>&1
	ok "Веб-панель установлена: http://$(lan_ip)/skyrim"
}

remove_panel() {
	local line
	for line in $PANEL_FILES; do rm -f "${line#*:}"; done
	rm -rf /www/skyrim /www/luci-static/skyrimvpn
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
	/etc/init.d/rpcd restart >/dev/null 2>&1
}

# ---------------------------------------------------------------- подписка
current_sub_url() { uci -q get $CFG.$SUB_ID.url || uci -q get $SET.main.sub_url; }

# Как часто обновлять подписку: сервер сам подсказывает в заголовке
# profile-update-interval (часы). Берём его в пределах 2–12 ч, иначе 4 ч.
sub_interval() {
	local h
	h=$(curl -sk -m 15 -A "passwall2" -D - -o /dev/null "$1" 2>/dev/null | tr -d '\r' \
		| grep -i '^profile-update-interval:' | head -1 | sed 's/^[^:]*: *//')
	case "$h" in ''|*[!0-9]*) h=4 ;; esac
	[ "$h" -lt 2 ] && h=2
	[ "$h" -gt 12 ] && h=12
	echo "$h"
}

ask_sub_url() {
	local old; old=$(current_sub_url)
	printf "\nСсылка на подписку есть в боте %s: «Подписка» → «Скопировать ссылку».\n" "$BOT"
	while :; do
		if [ -n "$old" ]; then ask "Вставьте ссылку (Enter — оставить текущую):"; [ -z "$ANSWER" ] && ANSWER="$old"
		else ask "Вставьте ссылку на подписку:"; fi
		ANSWER=$(echo "$ANSWER" | tr -d ' \r\t')
		valid_url "$ANSWER" && { SUB_URL="$ANSWER"; return 0; }
		err "Это не похоже на ссылку. Она должна начинаться с https:// — скопируйте её в боте заново."
	done
}

save_subscription() {
	uci -q delete $CFG.$SUB_ID
	uci set $CFG.$SUB_ID=subscribe_list
	uci set $CFG.$SUB_ID.remark="$GROUP"
	uci set $CFG.$SUB_ID.url="$1"
	uci set $CFG.$SUB_ID.user_agent="passwall2"
	uci set $CFG.$SUB_ID.hwid="$SEND_HWID"
	uci set $CFG.$SUB_ID.add_mode="2"
	# строки-разделители вида «⬇️ Если VLESS не работает ⬇️» — не серверы
	uci set $CFG.$SUB_ID.filter_keyword_mode="1"
	uci add_list $CFG.$SUB_ID.filter_discard_list="⬇️"
	# «АВТО» — группы автовыбора для приложений; на роутере такая ссылка не работает
	uci add_list $CFG.$SUB_ID.filter_discard_list="АВТО"
	# обновлять подписку при загрузке и с интервалом, который советует сервер
	local hours; hours=$(sub_interval "$1")
	uci set $CFG.$SUB_ID.boot_update="1"
	uci set $CFG.$SUB_ID.update_week_mode="8"
	uci set $CFG.$SUB_ID.update_interval_mode="$hours"
	uci commit $CFG
	settings_init
	uci set $SET.main.sub_url="$1"     # копия ссылки: переживёт перепрошивку роутера
	uci set $SET.main.sub_hours="$hours"
	uci commit $SET
}

# Таблица серверов из подписки за одно чтение настроек:
# id <TAB> протокол <TAB> транспорт <TAB> reality <TAB> название
# (только секции-узлы: у правила «Россия напрямую» та же группа).
node_table() {
	uci show $CFG 2>/dev/null | awk -v cfg="$CFG" -v grp="$GROUP" '
		{
			eq = index($0, "="); key = substr($0, 1, eq - 1); val = substr($0, eq + 1)
			gsub(/^'\''|'\''$/, "", val)
			n = split(key, k, ".")
			if (n == 2) { if (val == "nodes") { order[++cnt] = k[2]; isnode[k[2]] = 1 } }
			else if (n == 3) { f[k[2], k[3]] = val }
		}
		END {
			for (i = 1; i <= cnt; i++) { id = order[i]
				if (f[id, "group"] != grp) continue
				# пустые поля — «-»: shell-команда read склеивает подряд идущие табуляции
				printf "%s\t%s\t%s\t%s\t%s\n", id, d(f[id, "protocol"]), d(f[id, "transport"]), d(f[id, "reality"]), d(f[id, "remarks"]) }
		}
		function d(v) { return v == "" ? "-" : v }'
}
node_ids() { node_table | cut -f1; }
node_name() { uci -q get $CFG.$1.remarks; }

# Дождаться, пока PassWall закончит перезапуск: после обновления подписки он
# перезапускается в фоне и обрывает всё, что в этот момент проверяет серверы.
wait_pw_idle() {
	local i=0
	sleep 3
	while [ $i -lt 40 ] && ps w 2>/dev/null | grep -q "[i]nit.d/passwall2\|[p]asswall2/app.sh"; do
		sleep 2; i=$((i + 1))
	done
}

update_subscription() {
	say "Загружаю серверы из подписки…"
	lua /usr/share/passwall2/subscribe.lua start $SUB_ID >/dev/null 2>&1
	wait_pw_idle
	local n; n=$(node_ids | wc -l)
	if [ "$n" -eq 0 ]; then
		err "Серверы не загрузились."
		echo "  Возможные причины:"
		echo "   • подписка закончилась — продлите её в боте $BOT;"
		echo "   • ссылка скопирована не полностью;"
		echo "   • занят лимит устройств — освободите место в боте («Устройства»)."
		echo "  Журнал PassWall: tail -30 /tmp/log/passwall2.log"
		return 1
	fi
	ok "Загружено серверов: $n."
}

# ---------------------------------------------------------------- серверы
# Проверка сервера: поднимает временный Xray и меряет ответ. Выводит «мс» или пусто.
test_node() {
	local r code t
	r=$(/usr/share/passwall2/test.sh url_test_node "$1" 2>/dev/null | tail -1)
	code=${r%%:*}; t=${r#*:}
	case "$code" in 200|204) awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }' ;; esac
}

auto_pick() {
	# Проверяем быстрые серверы (⚡️), кроме «Мобильных» и «АВТО»: на домашнем интернете
	# белых списков нет, а «АВТО» — группы для приложения. ⭐ в названии = работает Gemini.
	# $1 — сервер, который пропустить (тот, что сейчас не отвечает)
	local ex="$1" ids id name ms best="" best_ms=999999 tab
	tab=$(printf '\t')
	ids=$(node_table | while IFS="$tab" read -r id _ _ _ name; do
		[ "$id" = "$ex" ] && continue
		case "$name" in *АВТО*|*Мобильн*) continue ;; esac
		case "$name" in *⚡*) echo "$id" ;; esac
	done | head -n 10)
	[ -z "$ids" ] && ids=$(node_table | while IFS="$tab" read -r id _ _ _ name; do
		[ "$id" = "$ex" ] && continue
		case "$name" in *АВТО*|*Мобильн*) continue ;; esac
		echo "$id"
	done | head -n 10)
	say "Ищу самый быстрый сервер (около минуты)…" >&2
	for id in $ids; do
		name=$(node_name "$id")
		ms=$(test_node "$id")
		if [ -n "$ms" ]; then
			printf "  %-45s %s мс\n" "$name" "$ms" >&2
			[ "$ms" -lt "$best_ms" ] && { best_ms=$ms; best=$id; }
		else
			printf "  %-45s нет ответа\n" "$name" >&2
		fi
	done
	echo "$best"
}

choose_server() {
	local ids id i=0 pick
	if [ "$AUTO" = "1" ]; then
		SERVER=$(auto_pick)
		[ -n "$SERVER" ] && { ok "Выбран сервер: $(node_name "$SERVER")"; return 0; }
		err "Ни один сервер не ответил."; return 1
	fi
	ids=$(node_ids)
	printf "\n${W}Серверы SkyrimVPN:${N}\n"
	for id in $ids; do
		i=$((i + 1))
		printf "  %2d) %s\n" "$i" "$(node_name "$id")"
	done
	printf "\n  ⭐ — работает Gemini   📱 — для мобильного интернета с белыми списками   🎮 — для игр\n"
	printf "  Enter — подобрать самый быстрый автоматически\n"
	ask "Номер сервера:"
	if [ -z "$ANSWER" ]; then
		pick=$(auto_pick)
		[ -n "$pick" ] || { err "Ни один сервер не ответил. Попробуйте выбрать вручную или проверьте подписку."; return 1; }
	else
		case "$ANSWER" in *[!0-9]*) err "Нужен номер из списка."; return 1 ;; esac
		pick=$(echo "$ids" | sed -n "${ANSWER}p")
		[ -n "$pick" ] || { err "Нет сервера с номером $ANSWER."; return 1; }
	fi
	SERVER="$pick"
	ok "Выбран сервер: $(node_name "$SERVER")"
}

# ---------------------------------------------------------------- маршрутизация
setup_routing() {
	local node="$1"
	# Правило: всё российское — напрямую (домены .ru .su .рф и российские IP).
	uci -q delete $CFG.$RULE_ID
	uci set $CFG.$RULE_ID=shunt_rules
	uci set $CFG.$RULE_ID.remarks="SkyrimVPN: Россия напрямую"
	uci set $CFG.$RULE_ID.network="tcp,udp"
	uci set $CFG.$RULE_ID.group="$GROUP"
	uci set $CFG.$RULE_ID.domain_list="domain:ru
domain:su
domain:xn--p1ai"
	uci set $CFG.$RULE_ID.ip_list="geoip:ru"
	uci reorder $CFG.$RULE_ID=0

	# Узел-маршрутизатор: правило выше — напрямую, остальное — в выбранный сервер.
	uci -q delete $CFG.$SHUNT_ID
	uci set $CFG.$SHUNT_ID=nodes
	uci set $CFG.$SHUNT_ID.remarks="SkyrimVPN (Россия напрямую)"
	uci set $CFG.$SHUNT_ID.type="Xray"
	uci set $CFG.$SHUNT_ID.protocol="_shunt"
	uci set $CFG.$SHUNT_ID.shunt_group="$GROUP"
	uci set $CFG.$SHUNT_ID.$RULE_ID="_direct"
	uci set $CFG.$SHUNT_ID.PrivateIP="_direct"
	uci set $CFG.$SHUNT_ID.default_node="$node"
	uci set $CFG.$SHUNT_ID.domainStrategy="IPOnDemand"
	uci set $CFG.$SHUNT_ID.domainMatcher="hybrid"
	uci set $CFG.$SHUNT_ID.write_ipset_direct="1"
	uci set $CFG.$SHUNT_ID.enable_geoview_ip="1"

	uci set $CFG.@global[0].node="$SHUNT_ID"
	uci set $CFG.@global[0].enabled="1"
	uci commit $CFG
}

# Работает ли сам VPN (основной процесс Xray PassWall, а не временная проверка сервера).
vpn_running() { ps w 2>/dev/null | grep -q "[a]cl_default.json"; }

vpn_restart() {
	say "Запускаю VPN…"
	/etc/init.d/passwall2 enable >/dev/null 2>&1
	/etc/init.d/passwall2 restart >/dev/null 2>&1
}

# Ждём, пока заработает (правила грузятся 10–30 секунд), и проверяем выход в интернет.
# Почему VPN не работает — понятным языком.
diagnose() {
	if ! vpn_running; then
		err "VPN не запустился. Журнал: tail -30 /tmp/log/passwall2.log — пришлите его в поддержку."
	else
		net_state_direct; pw_resume
		net_msg "$NET"
	fi
}

# verify [quiet] — работает ли VPN; quiet — без объяснения причины при неудаче
verify() {
	local i=0 code tries=20
	[ "$1" = "quiet" ] && tries=10      # ~1,5 минуты: дальше сразу ищем другой сервер
	while [ $i -lt $tries ]; do
		code=$(curl -s -o /dev/null -m 6 -w "%{http_code}" https://www.youtube.com/generate_204 2>/dev/null)
		[ "$code" = "204" ] && break
		sleep 3; i=$((i + 1))
	done
	if [ "$code" != "204" ]; then
		[ "$1" = "quiet" ] || diagnose
		return 1
	fi
	local ip country
	ip=$(curl -s -m 8 https://ifconfig.co/ip 2>/dev/null | grep -E '^[0-9a-fA-F.:]+$')
	country=$(curl -s -m 8 https://ifconfig.co/country 2>/dev/null | grep -E '^[A-Za-z .-]{2,40}$')
	ok "VPN работает. Внешний IP: ${ip:-?} ${country:+($country)}"
	if curl -s -o /dev/null -m 8 https://gosuslugi.ru 2>/dev/null; then
		ok "Госуслуги открываются напрямую — российские сайты идут мимо VPN."
	fi
}

# ---------------------------------------------------------------- настройки и события
settings_init() {
	[ -f /etc/config/$SET ] || printf "config skyrim 'main'\n" >/etc/config/$SET
	uci -q get $SET.main >/dev/null || { uci set $SET.main=skyrim; uci commit $SET; }
	[ -n "$(uci -q get $SET.main.watchdog)" ] || uci set $SET.main.watchdog="1"
	[ -n "$(uci -q get $SET.main.autoswitch)" ] || uci set $SET.main.autoswitch="1"
	[ -n "$(uci -q get $SET.main.restore)" ] || uci set $SET.main.restore="1"
	uci commit $SET
}
setting() { uci -q get $SET.main.$1; }

# Занят ли роутер командой. «Замок» без живого процесса (сбой, перезагрузка) снимается сам.
lock_busy() {
	[ -d "$LOCK" ] || return 1
	local p; p=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$p" ]; then kill -0 "$p" 2>/dev/null && return 0
	elif [ $(( $(date +%s) - $(date -r "$LOCK" +%s 2>/dev/null || date +%s) )) -lt 60 ]; then return 0; fi
	rm -rf "$LOCK"
	return 1
}

# Запись в журнал событий: $1 — ok|warn|err|info, $2 — текст. Храним последние 100.
event() {
	echo "$(date +%s)|$1|$2" >>"$EVENTS"
	[ "$(wc -l <"$EVENTS")" -gt 120 ] && { tail -100 "$EVENTS" >"$EVENTS.tmp"; mv "$EVENTS.tmp" "$EVENTS"; }
}

# Из базы адресов (16+ МБ) оставляем только Россию и локальные сети (~0,4 МБ):
# правило «Россия напрямую» использует только geoip:ru. Освобождает ~16 МБ флеша.
shrink_geo() {
	local f=/usr/share/v2ray/geoip.dat
	[ -f "$f" ] && [ -x /usr/bin/geoview ] || return 0
	[ "$(wc -c <"$f")" -gt 2000000 ] || return 0
	geoview -type geoip -input "$f" -list ru,private -action convert -format geoip -output /tmp/geoip-ru.dat >/dev/null 2>&1 || return 0
	# проверка: в урезанной базе российский адрес должен определяться как RU
	geoview -type geoip -input /tmp/geoip-ru.dat -action lookup -value 77.88.8.8 2>/dev/null | grep -qi '^ru' || { rm -f /tmp/geoip-ru.dat; return 0; }
	mv /tmp/geoip-ru.dat "$f"
	# PassWall не должен скачивать полную базу обратно при обновлении правил
	uci set $CFG.@global_rules[0].geoip_update="0"
	uci commit $CFG
	return 0
}

# Работает ли интернет через VPN (сам роутер тоже ходит через VPN).
vpn_ok() {
	local u
	for u in https://www.youtube.com/generate_204 https://www.google.com/generate_204; do
		[ "$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$u" 2>/dev/null)" = "204" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------- «Сторож»
# Запускается cron'ом каждые 3 минуты. Ничего не делает, если VPN выключен,
# роутер только что загрузился или занят другой командой.
WD_FAIL=/tmp/skyrim-wd.fail

do_watchdog() {
	[ "$(setting watchdog)" = "0" ] && return 0
	is_installed || return 0
	[ "$(uci -q get $CFG.@global[0].enabled)" = "1" ] || return 0
	[ "$(cut -d. -f1 /proc/uptime)" -lt 240 ] && return 0      # PassWall стартует с задержкой 60 с
	lock_busy && return 0
	shrink_geo

	if ! vpn_running; then
		sleep 30; vpn_running && return 0                         # возможно, как раз перезапускается
		event warn "VPN не работал — перезапустил."
		/etc/init.d/passwall2 restart >/dev/null 2>&1
		return 0
	fi
	vpn_ok && { rm -f "$WD_FAIL"; return 0; }

	net_state_direct; pw_resume
	case "$NET" in
		down) [ -f "$WD_FAIL.net" ] || event info "Нет интернета у провайдера — VPN ни при чём, жду."; touch "$WD_FAIL.net"; return 0 ;;
		dns)  [ -f "$WD_FAIL.net" ] || event info "У провайдера не работает DNS — жду."; touch "$WD_FAIL.net"; return 0 ;;
	esac
	rm -f "$WD_FAIL.net"

	local n cur name best
	n=$(( $(cat "$WD_FAIL" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$WD_FAIL"
	[ "$n" -lt 2 ] && return 0                                    # одна осечка — ещё не повод
	rm -f "$WD_FAIL"

	cur=$(uci -q get $CFG.$SHUNT_ID.default_node); name=$(node_name "$cur")
	if [ "$(setting autoswitch)" = "0" ]; then
		event warn "Сервер «$name» не отвечает. Автовыбор выключен — смените сервер в панели."
		return 0
	fi
	mkdir "$LOCK" 2>/dev/null || return 0
	echo "Сторож ищет рабочий сервер…" >"$LOCK/label"; echo $$ >"$LOCK/pid"
	pw_pause                                                     # мёртвый сервер не мешает проверкам
	best=$(auto_pick "$cur" 2>/dev/null)
	if [ -n "$best" ]; then
		setup_routing "$best"
		/etc/init.d/passwall2 restart >/dev/null 2>&1
		event ok "Сервер «$name» не отвечал — переключил на «$(node_name "$best")»."
	else
		/etc/init.d/passwall2 start >/dev/null 2>&1
		event err "Сервер «$name» не отвечает, и другие тоже. Возможно, закончилась подписка."
	fi
	rm -rf "$LOCK"
}

# ---------------------------------------------------------------- системные «крючки»
# cron — «Сторож»; rc.local — восстановление после перепрошивки;
# sysupgrade.conf — сохранить скрипт при обновлении прошивки.
CRON_LINE="*/3 * * * * /usr/bin/skyrim watchdog >/dev/null 2>&1 # SkyrimVPN"
RC_LINE="[ -x /usr/bin/skyrim ] && (/usr/bin/skyrim boot >/tmp/skyrim-boot.log 2>&1 &) # SkyrimVPN"

install_hooks() {
	settings_init
	touch /etc/crontabs/root
	sed -i '/# SkyrimVPN$/d' /etc/crontabs/root
	echo "$CRON_LINE" >>/etc/crontabs/root
	/etc/init.d/cron enable >/dev/null 2>&1; /etc/init.d/cron restart >/dev/null 2>&1
	if [ -f /etc/rc.local ]; then
		sed -i '/# SkyrimVPN$/d' /etc/rc.local
		# вставляем перед «exit 0» (через awk: в строке есть «&», который sed понял бы по-своему)
		if grep -q '^exit 0' /etc/rc.local; then
			awk -v l="$RC_LINE" '/^exit 0/ && !d { print l; d = 1 } { print }' /etc/rc.local >/tmp/rc.local.new \
				&& cat /tmp/rc.local.new >/etc/rc.local && rm -f /tmp/rc.local.new
		else
			echo "$RC_LINE" >>/etc/rc.local
		fi
	fi
	# скрипт и файлы панели переживут обновление прошивки — восстановление не зависит от GitHub
	touch /etc/sysupgrade.conf
	local f line
	for f in /usr/bin/skyrim $(for line in $PANEL_FILES; do echo "${line#*:}"; done); do
		grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >>/etc/sysupgrade.conf
	done
}

remove_hooks() {
	sed -i '/# SkyrimVPN$/d' /etc/crontabs/root /etc/rc.local 2>/dev/null
	local line
	sed -i '\|^/usr/bin/skyrim$|d' /etc/sysupgrade.conf 2>/dev/null
	for line in $PANEL_FILES; do sed -i "\\|^${line#*:}\$|d" /etc/sysupgrade.conf 2>/dev/null; done
	/etc/init.d/cron restart >/dev/null 2>&1
	rm -f /etc/config/$SET "$EVENTS" "$WD_FAIL" "$WD_FAIL.net"
}

# При каждой загрузке роутера. Если программы пропали (обновили прошивку,
# а настройки сохранились) — ставим всё заново сами, с той же подпиской.
do_boot() {
	is_installed && return 0
	[ "$(setting restore)" = "0" ] && return 0
	local url; url=$(setting sub_url)
	[ -n "$url" ] || return 0
	local i=0
	while [ $i -lt 30 ] && [ "$(net_state)" != "ok" ]; do sleep 10; i=$((i + 1)); done
	event info "После обновления прошивки VPN пропал — восстанавливаю автоматически."
	if AUTO=1 sh /usr/bin/skyrim install "$url" >/tmp/skyrim-restore.log 2>&1; then
		event ok "VPN восстановлен после обновления прошивки."
	else
		event err "Не удалось восстановить VPN после обновления прошивки. Запустите установку заново."
	fi
}

# ---------------------------------------------------------------- действия меню
do_install() {
	check_resources
	check_internet
	if ! is_installed; then
		add_feeds
		swap_dnsmasq
		install_packages
	fi
	shrink_geo && ok "Свободно на флеше после оптимизации: $(( $(free_kb) / 1024 )) МБ."
	install_self
	install_panel
	install_hooks
	if [ -n "$1" ] && valid_url "$1"; then SUB_URL="$1"
	elif [ "$AUTO" = "1" ]; then die "Нет ссылки на подписку."
	else ask_sub_url; fi
	save_subscription "$SUB_URL"
	update_subscription || exit 1
	choose_server || exit 1
	setup_routing "$SERVER"
	vpn_restart
	if verify_or_fallback; then
		event ok "SkyrimVPN установлен, сервер «$(node_name "$SERVER")»."
		finish_text
	else
		event warn "SkyrimVPN установлен, но подключение не проходит."
		printf "\n${Y}SkyrimVPN установлен, но VPN пока не работает${N} — причина написана выше.\n"
		printf "  • Сменить сервер: панель ${W}http://%s/skyrim${N} или команда ${W}skyrim${N} → 1\n" "$(lan_ip)"
		printf "  • «Сторож» тоже будет пробовать другие серверы каждые 3 минуты.\n"
		printf "  • Не помогло — команда ${W}skyrim report${N}, отчёт пришлите в %s\n\n" "$SUPPORT"
		exit 1
	fi
}

# Проверяем выбранный сервер; если он не отвечает, а интернет у роутера есть —
# сами подбираем рабочий (кроме него) и проверяем ещё раз.
verify_or_fallback() {
	verify quiet && return 0
	vpn_running || { diagnose; return 1; }
	net_state_direct
	[ "$NET" = "ok" ] || { pw_resume; net_msg "$NET"; return 1; }
	warn "Сервер «$(node_name "$SERVER")» не отвечает — подбираю рабочий автоматически."
	# пока ищем, мёртвый сервер не должен мешать проверкам
	pw_pause; PW_HELD=0
	local best; best=$(auto_pick "$SERVER")
	if [ -z "$best" ]; then
		/etc/init.d/passwall2 start >/dev/null 2>&1
		err "Ни один сервер не ответил. Попробуйте позже или напишите в поддержку."; return 1
	fi
	SERVER=$best
	ok "Выбран сервер: $(node_name "$SERVER")"
	setup_routing "$SERVER"
	vpn_restart
	verify
}

lan_ip() { local ip; ip=$(uci -q get network.lan.ipaddr | cut -d/ -f1); echo "${ip:-192.168.1.1}"; }

finish_text() {
	printf "\n${G}Готово!${N} VPN работает для всех устройств, подключённых к роутеру.\n"
	printf "  • Панель SkyrimVPN: ${W}http://%s/skyrim${N} (пароль — как от роутера)\n" "$(lan_ip)"
	printf "    На телефоне: откройте её и «Добавить на главный экран» — будет иконка-приложение.\n"
	printf "  • Или в консоли роутера: ${W}skyrim${N}\n"
	printf "  • Подписка обновляется сама каждые %s ч, «Сторож» проверяет VPN каждые 3 минуты\n" "$(setting sub_hours)"
	printf "    и сам меняет сервер, если тот перестал отвечать.\n"
	printf "  • Обновили прошивку роутера? VPN восстановится сам после перезагрузки.\n"
	printf "  • Вопросы: %s\n\n" "$SUPPORT"
}

do_change_server() {
	is_installed || { err "Сначала установите SkyrimVPN (пункт 1)."; return; }
	choose_server || return
	setup_routing "$SERVER"
	vpn_restart
	verify_or_fallback
}

do_update_sub() {
	[ -n "$(current_sub_url)" ] || { err "Подписка ещё не добавлена."; return; }
	update_subscription || return
	# если выбранный сервер исчез из подписки — предлагаем выбрать новый
	local cur; cur=$(uci -q get $CFG.$SHUNT_ID.default_node)
	if [ -n "$cur" ] && [ -z "$(node_name "$cur")" ]; then
		warn "Ваш сервер пропал из подписки — выберите новый."
		do_change_server
	else
		vpn_restart; verify
	fi
}

do_change_sub() {
	ask_sub_url
	save_subscription "$SUB_URL"
	update_subscription || return
	do_change_server
}

do_toggle() {
	local want="$1"
	[ -z "$want" ] && { [ "$(uci -q get $CFG.@global[0].enabled)" = "1" ] && want=off || want=on; }
	if [ "$want" = "off" ]; then
		uci set $CFG.@global[0].enabled="0"; uci commit $CFG
		/etc/init.d/passwall2 stop >/dev/null 2>&1
		ok "VPN выключен. Интернет идёт напрямую."
	else
		uci set $CFG.@global[0].enabled="1"; uci commit $CFG
		vpn_restart; verify
	fi
}

do_status() {
	if ! is_installed; then warn "SkyrimVPN не установлен."; return; fi
	local en node
	en=$(uci -q get $CFG.@global[0].enabled)
	node=$(uci -q get $CFG.$SHUNT_ID.default_node)
	printf "  PassWall 2:   %s\n" "$(pw_version)"
	printf "  VPN:          %b\n" "$([ "$en" = "1" ] && echo "${G}включён${N}" || echo "${Y}выключен${N}")"
	printf "  Сервер:       %s\n" "${node:+$(node_name "$node")}"
	printf "  Серверов:     %s\n" "$(node_ids | wc -l)"
	printf "  Xray:         %b\n" "$(vpn_running && echo "${G}работает${N}" || echo "${Y}не запущен${N}")"
	printf "  Флеш свободно: %s МБ\n" "$(( $(free_kb) / 1024 ))"
	[ "$en" = "1" ] && [ "$1" != "quick" ] && verify
}

# Отчёт для поддержки: без ссылки на подписку, ключей и IP-адресов.
do_report() {
	local node; node=$(uci -q get $CFG.$SHUNT_ID.default_node)
	echo "=== SkyrimVPN Router $VERSION — отчёт $(date '+%d.%m.%Y %H:%M') ==="
	echo "OpenWrt: $RELEASE ($ARCH), пакеты: $PKG"
	echo "Модель: $(cat /tmp/sysinfo/model 2>/dev/null)"
	echo "Память: $(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) МБ, флеш свободно: $(( $(free_kb) / 1024 )) МБ"
	echo "PassWall 2: $(pw_version), Xray: $(xray version 2>/dev/null | head -1 | awk '{print $2}')"
	echo "VPN включён: $(uci -q get $CFG.@global[0].enabled), работает: $(vpn_running && echo да || echo нет)"
	echo "Сервер: ${node:+$(node_name "$node")} ($(uci -q get $CFG.$node.protocol) $(uci -q get $CFG.$node.transport))"
	echo "Серверов: $(node_ids | wc -l), подписка до: $(uci -q get $CFG.$SUB_ID.expired_date)"
	echo "Сеть: $(net_state), время: $(date +%Y)"
	echo "YouTube через VPN: $(curl -s -o /dev/null -m 8 -w '%{http_code}' https://www.youtube.com/generate_204 2>/dev/null)"
	echo "--- журнал PassWall (последние строки) ---"
	tail -25 /tmp/log/passwall2.log 2>/dev/null | sed -E 's#https?://[^ ]+#<ссылка>#g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g'
	echo "=== конец отчёта ==="
}

do_uninstall() {
	yes_no "Удалить SkyrimVPN, PassWall 2 и Xray с роутера?" || return
	say "Удаляю…"
	/etc/init.d/passwall2 stop >/dev/null 2>&1
	/etc/init.d/passwall2 disable >/dev/null 2>&1
	pkg_remove luci-i18n-passwall2-ru
	pkg_remove luci-app-passwall2 xray-core v2ray-geoip v2ray-geosite geoview
	rm -f /etc/config/passwall2 /etc/config/passwall2_server
	sed -i '/openwrt-passwall-build/d' /etc/opkg/customfeeds.conf /etc/apk/repositories.d/customfeeds.list 2>/dev/null
	rm -f /etc/apk/keys/passwall.pem
	if yes_no "Вернуть обычный dnsmasq вместо dnsmasq-full? (можно оставить — не мешает)"; then
		cd /tmp || return
		if [ "$PKG" = "apk" ]; then
			apk fetch dnsmasq >>/tmp/skyrim-pkg.log 2>&1 && apk del dnsmasq-full >>/tmp/skyrim-pkg.log 2>&1 && apk add --allow-untrusted /tmp/dnsmasq-[0-9]*.apk >>/tmp/skyrim-pkg.log 2>&1
		else
			opkg download dnsmasq >>/tmp/skyrim-pkg.log 2>&1 && opkg remove dnsmasq-full >>/tmp/skyrim-pkg.log 2>&1 && opkg install /tmp/dnsmasq_*.ipk >>/tmp/skyrim-pkg.log 2>&1
		fi
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi
	remove_panel
	remove_hooks
	rm -f /usr/bin/skyrim
	ok "SkyrimVPN удалён. Интернет идёт напрямую."
	exit 0
}

menu() {
	while :; do
		banner
		if is_installed; then
			do_status quick
			printf "\n  1) Сменить сервер\n  2) Обновить подписку\n  3) Вставить другую ссылку на подписку\n"
			printf "  4) %s VPN\n" "$([ "$(uci -q get $CFG.@global[0].enabled)" = "1" ] && echo "Выключить" || echo "Включить")"
			printf "  5) Проверить подключение\n  6) Отчёт для поддержки\n  7) Обновить скрипт и веб-панель\n"
			printf "  8) Переустановить\n  9) Удалить SkyrimVPN\n  0) Выход\n\n"
			ask "Выберите пункт:"
			case "$ANSWER" in
				1) do_change_server ;; 2) do_update_sub ;; 3) do_change_sub ;; 4) do_toggle ;;
				5) verify ;; 6) do_report ;;
				7) install_self force; install_panel; ok "Скрипт и панель обновлены — запустите skyrim заново."; exit 0 ;;
				8) do_install ;;
				9) do_uninstall ;; 0|q|"") exit 0 ;;
				*) err "Нет такого пункта." ;;
			esac
		else
			printf "  SkyrimVPN ещё не установлен на этот роутер.\n\n  1) Установить\n  0) Выход\n\n"
			ask "Выберите пункт:"
			case "$ANSWER" in
				1) do_install; exit 0 ;; 0|q|"") exit 0 ;;
				*) err "Нет такого пункта." ;;
			esac
		fi
		pause
	done
}

# ---------------------------------------------------------------- точка входа
# SKYRIM_LIB=1 — подключить как библиотеку (так делает веб-панель), без запуска меню.
[ "$SKYRIM_LIB" = "1" ] && return 0 2>/dev/null
detect_system
case "$1" in
	install) banner; do_install "$2" ;;
	panel)   install_self force; install_panel ;;
	server)  do_change_server ;;
	update)  do_update_sub ;;
	on|off)  do_toggle "$1" ;;
	status)  do_status ;;
	report)  do_report ;;
	watchdog) do_watchdog ;;
	boot)    do_boot ;;
	events)  [ -f "$EVENTS" ] && while IFS='|' read -r t l m; do echo "$(date -d "@$t" '+%d.%m %H:%M' 2>/dev/null) $m"; done <"$EVENTS" ;;
	remove)  do_uninstall ;;
	version) echo "$VERSION" ;;
	"")      menu ;;
	*) echo "Команды: skyrim [install|server|update|on|off|status|report|panel|remove]" ;;
esac
