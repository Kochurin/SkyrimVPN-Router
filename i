#!/bin/sh
# SkyrimVPN Router — короткая команда установки:
#   sh <(wget -qO- https://kochurin.github.io/SkyrimVPN-Router/i)
# Скачивает установщик с первого доступного зеркала и запускает его.

R="Kochurin/SkyrimVPN-Router"
for u in \
	"https://kochurin.github.io/SkyrimVPN-Router/skyrim.sh" \
	"https://raw.githubusercontent.com/$R/main/skyrim.sh" \
	"https://cdn.jsdelivr.net/gh/$R@main/skyrim.sh"
do
	if wget -q -T 20 -O /tmp/skyrim.sh "$u" 2>/dev/null && head -c 300 /tmp/skyrim.sh | grep -q "SkyrimVPN Router" && sh -n /tmp/skyrim.sh; then
		exec sh /tmp/skyrim.sh install "$@"
	fi
done
rm -f /tmp/skyrim.sh
echo "Не удалось скачать установщик SkyrimVPN: GitHub недоступен с роутера."
echo "Проверьте интернет на роутере и попробуйте через пару минут. Поддержка: t.me/SkyrimVPN_help_bot"
exit 1
