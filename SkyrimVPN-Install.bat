@echo off
chcp 65001 >nul
title Установка SkyrimVPN на роутер
color 0F
cls
echo.
echo    ==============================================
echo      SkyrimVPN — установка VPN на роутер OpenWrt
echo    ==============================================
echo.
echo    Перед началом:
echo     1. Компьютер подключён к роутеру (Wi-Fi или кабель).
echo     2. VPN на компьютере ВЫКЛЮЧЕН.
echo     3. Ссылка на подписку скопирована в боте @SkyrimVPN_bot
echo        (Подписка - Скопировать ссылку).
echo.

where ssh >nul 2>nul
if errorlevel 1 (
  echo    [!] В этой Windows нет программы SSH.
  echo        Параметры - Приложения - Дополнительные компоненты -
  echo        Добавить компонент - "Клиент OpenSSH", затем запустите этот файл снова.
  echo.
  pause
  exit /b 1
)

set "ROUTER=192.168.1.1"
set /p "ROUTER=   Адрес роутера (просто Enter = 192.168.1.1): "
echo.
echo    Сейчас роутер спросит пароль — это пароль от его настроек
echo    (тот же, что в браузере). Символы при вводе не видны — так и должно быть.
echo.

ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 root@%ROUTER% "wget -qO /tmp/i https://kochurin.github.io/SkyrimVPN-Router/i || wget -qO /tmp/i https://raw.githubusercontent.com/Kochurin/SkyrimVPN-Router/main/i; sh /tmp/i"

if errorlevel 255 (
  echo.
  echo    [!] Не удалось подключиться к роутеру %ROUTER%.
  echo        - Проверьте, что компьютер подключён к этому роутеру.
  echo        - Проверьте адрес роутера ^(обычно 192.168.1.1^).
  echo        - На роутере должна стоять прошивка OpenWrt.
)
echo.
echo    Панель SkyrimVPN: http://%ROUTER%/skyrim
echo    Поддержка: t.me/SkyrimVPN_help_bot
echo.
pause
