/*
 * SkyrimVPN — панель на роутере (http://<роутер>/skyrim/).
 * Говорит с роутером через ubus (/ubus): вход — session.login, данные — объект «skyrimvpn».
 * https://github.com/Kochurin/SkyrimVPN-Router
 */
(function () {
	'use strict';

	var LINKS = {
		bot: 'https://t.me/SkyrimVPN_bot',
		support: 'https://t.me/SkyrimVPN_help_bot',
		site: 'https://skyrim.connecto.lol',
		channel: 'https://t.me/skyrimVPN'
	};
	var NO_SESSION = '00000000000000000000000000000000';
	var SESSION_TTL = 7 * 24 * 3600;   // вход живёт неделю (до перезагрузки роутера)

	var ICON = {
		power: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M12 3v8"/><path d="M6.3 6.8a8 8 0 1 0 11.4 0"/></svg>',
		logout: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="M10 17l-5-5 5-5"/><path d="M5 12h11"/></svg>'
	};

	var S = {
		sid: store('skv_sid') || null,
		st: {}, servers: [], filter: 'all', ms: {}, testing: false,
		ip: null, timer: null, wasBusy: false
	};
	var $app = document.getElementById('app');

	/* ---------- мелочи ---------- */

	function store(k, v) {
		try {
			if (v === undefined) return localStorage.getItem(k);
			if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v);
		} catch (e) { return null; }
	}

	function h(tag, attrs, kids) {
		var n = document.createElement(tag);
		if (attrs) for (var k in attrs) {
			var v = attrs[k];
			if (v == null || v === false) continue;
			if (k === 'html') n.innerHTML = v;
			else if (k.slice(0, 2) === 'on') n.addEventListener(k.slice(2), v);
			else n.setAttribute(k, v === true ? '' : v);
		}
		(Array.isArray(kids) ? kids : [ kids ]).forEach(function (c) {
			if (c == null || c === false || c === '') return;
			n.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
		});
		return n;
	}

	function toast(text, isErr) {
		var t = h('div', { 'class': 'toast' + (isErr ? ' err' : '') }, text);
		document.body.appendChild(t);
		setTimeout(function () { t.remove(); }, isErr ? 6000 : 3500);
	}

	function ext(href, text, cls) { return h('a', { href: href, target: '_blank', rel: 'noopener', 'class': cls }, text); }

	function flagCode(name) {
		var m = (name || '').match(/([\u{1F1E6}-\u{1F1FF}])([\u{1F1E6}-\u{1F1FF}])/u);
		if (!m) return '';
		return String.fromCharCode(m[1].codePointAt(0) - 0x1F1E6 + 65, m[2].codePointAt(0) - 0x1F1E6 + 65);
	}

	function cleanName(name) {
		var s = (name || '').replace(/[\u{1F1E6}-\u{1F1FF}]/gu, '')
			.replace(/\p{Extended_Pictographic}|️|‍|✅/gu, '')
			.replace(/\s*\|\s*/g, ' · ').replace(/\s+/g, ' ').replace(/^[\s·]+|[\s·]+$/g, '');
		return s || 'Сервер';
	}

	function protoLabel(s) {
		if (s.protocol === 'hysteria2') return 'Hysteria2';
		var t = { raw: 'TCP', tcp: 'TCP', ws: 'WS', grpc: 'gRPC', xhttp: 'XHTTP', splithttp: 'XHTTP', httpupgrade: 'HTTPUpgrade' }[s.transport] || (s.transport || '').toUpperCase();
		return s.reality ? 'Reality' + (t && t !== 'TCP' ? ' · ' + t : '') : (t || s.protocol || '');
	}

	// ⭐ в названии = работает Gemini; 📱 = мобильный интернет с белыми списками; 🎮 = игры
	function cats(name) {
		var c = [];
		if (/⭐/.test(name)) c.push('gemini');
		if (/📱|Мобильн/i.test(name)) c.push('mobile');
		if (/🎮|Hysteria/i.test(name)) c.push('game');
		if (/Torrent/i.test(name)) c.push('torrent');
		if (/⚡/.test(name)) c.push('fast');
		return c;
	}

	function parseExpire(s) {
		var m = (s || '').match(/(\d{4})-(\d{1,2})-(\d{1,2})/);
		return m ? new Date(+m[1], +m[2] - 1, +m[3], 23, 59) : null;
	}

	function plural(n, a, b, c) {
		n = Math.abs(n) % 100; var n1 = n % 10;
		if (n > 10 && n < 20) return c;
		if (n1 > 1 && n1 < 5) return b;
		return n1 === 1 ? a : c;
	}

	/* ---------- связь с роутером ---------- */

	function NeedLogin() {}

	function rpc(sid, obj, method, params) {
		return fetch('/ubus', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: [ sid, obj, method, params || {} ] })
		}).then(function (r) {
			if (!r.ok) throw new Error('HTTP ' + r.status);
			return r.json();
		}).then(function (j) {
			if (j.error) {
				if (j.error.code === -32002) throw new NeedLogin();
				throw new Error(j.error.message || 'ошибка');
			}
			var code = j.result && j.result[0];
			if (code === 6) throw new NeedLogin();          // нет прав — истёк вход
			if (code !== 0) throw new Error(code === 4 ? 'нет ответа от панели (перезапустите роутер)' : 'код ' + code);
			return j.result[1] || {};
		});
	}

	function call(method, params) {
		if (!S.sid) return Promise.reject(new NeedLogin());
		return rpc(S.sid, 'skyrimvpn', method, params).catch(function (e) {
			if (e instanceof NeedLogin) { S.sid = null; store('skv_sid', null); showLogin(); }
			throw e;
		});
	}

	function failed(e) {
		if (e instanceof NeedLogin) return;
		toast(e && e.message === 'Failed to fetch' ? 'Нет связи с роутером' : 'Ошибка: ' + (e && e.message), true);
	}

	/* ---------- вход ---------- */

	function showLogin(msg) {
		clearTimeout(S.timer);
		var err = h('div', { 'class': 'err' }, msg || '');
		var pw = h('input', { 'class': 'input', type: 'password', placeholder: 'Пароль от роутера', autocomplete: 'current-password' });
		var btn = h('button', { 'class': 'btn solid', type: 'submit' }, 'Войти');
		var form = h('form', { onsubmit: function (ev) {
			ev.preventDefault();
			btn.disabled = true; err.textContent = '';
			rpc(NO_SESSION, 'session', 'login', { username: 'root', password: pw.value, timeout: SESSION_TTL })
				.then(function (r) {
					if (!r.ubus_rpc_session) throw new Error();
					S.sid = r.ubus_rpc_session; store('skv_sid', S.sid);
					start();
				})
				.catch(function (e) {
					btn.disabled = false;
					err.textContent = e && e.message === 'Failed to fetch' ? 'Нет связи с роутером.' : 'Неверный пароль.';
					pw.select();
				});
		} }, [ pw, btn, err ]);

		$app.replaceChildren(h('div', { 'class': 'login' }, h('div', { 'class': 'box' }, [
			h('img', { src: 'dragon.png', alt: '' }),
			h('div', { 'class': 'brand' }, 'SkyrimVPN'),
			h('div', { 'class': 'sub' }, 'Панель VPN на вашем роутере'),
			form,
			h('div', { 'class': 'hint' }, 'Пароль тот же, что для входа в настройки роутера.')
		])));
		setTimeout(function () { pw.focus(); }, 50);
	}

	function logout() {
		if (S.sid) rpc(S.sid, 'session', 'destroy', {}).catch(function () {});
		S.sid = null; store('skv_sid', null);
		showLogin();
	}

	/* ---------- экран ---------- */

	var box = {};

	function start() {
		$app.replaceChildren(h('div', { 'class': 'skeleton' }, 'Загрузка…'));
		Promise.all([ call('status'), call('servers') ]).then(function (r) {
			S.st = r[0]; S.servers = r[1].servers || [];
			build();
		}).catch(failed);
	}

	function build() {
		if (!S.st.installed) {
			$app.replaceChildren(head(), h('div', { 'class': 'card', style: 'text-align:center;padding:50px 20px' }, [
				h('img', { src: 'dragon.png', alt: '', style: 'height:120px;margin-bottom:16px' }),
				h('h2', {}, 'SkyrimVPN ещё не настроен'),
				h('p', { 'class': 'sub' }, 'Зайдите на роутер по SSH и выполните команду установки из инструкции.')
			]), banner(), foot());
			return;
		}
		box.hero = h('div'); box.sub = h('div'); box.srv = h('div'); box.wd = h('div');
		$app.replaceChildren(head(), box.hero, box.sub, banner(), box.srv, box.wd, foot());
		paint();
		loadIp();
		loadEvents();
		schedule();
	}

	function paint() { paintHero(); paintSub(); paintServers(); paintWd(); }

	/* --- «Сторож» и журнал событий --- */
	function loadEvents() {
		call('events').then(function (r) { S.events = r.events || []; paintWd(); }).catch(function () {});
	}

	function sw(label, hint, on, onChange) {
		var input = h('input', { type: 'checkbox', checked: on ? true : null, onchange: function () { onChange(input.checked); } });
		return h('label', { 'class': 'sw' }, [
			h('span', { 'class': 'swtxt' }, [ label, h('small', {}, hint) ]),
			input, h('span', { 'class': 'swbox' })
		]);
	}

	function paintWd() {
		if (!box.wd) return;
		var st = S.st, ev = S.events || [];
		var save = function (wd, as) {
			call('settings', { watchdog: wd, autoswitch: as }).then(function () {
				S.st.watchdog = wd; S.st.autoswitch = as; paintWd();
				toast(wd ? (as ? 'Сторож следит и сам меняет сервер' : 'Сторож только сообщает о проблемах') : 'Сторож выключен');
			}).catch(failed);
		};
		var fmt = function (t) {
			var d = new Date(t * 1000);
			return d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' }) + ' ' + d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
		};
		box.wd.replaceChildren(h('div', { 'class': 'card' }, [
			h('h3', {}, 'Сторож'),
			h('p', { 'class': 'sub', style: 'margin:-6px 0 14px' }, 'Каждые 3 минуты проверяет, работает ли VPN. Подписка обновляется каждые ' + (st.sub_hours || 4) + ' ч.'),
			sw('Следить за VPN', 'Если VPN «упал» — перезапустит его сам', st.watchdog !== false, function (v) { save(v, st.autoswitch !== false); }),
			sw('Сам менять упавший сервер', 'Сервер не отвечает 2 проверки подряд — переключит на самый быстрый', st.autoswitch !== false && st.watchdog !== false,
				function (v) { save(true, v); }),
			h('div', { 'class': 'events' }, ev.length ? ev.slice(0, 12).map(function (e) {
				// в тексте — названия серверов с эмодзи: «🇫🇮 ⚡️ Финляндия #4» → «Финляндия #4»
				var text = (e.text || '').replace(/«([^»]*)»/g, function (m, n) { return '«' + cleanName(n) + '»'; });
				return h('div', { 'class': 'ev ' + e.level }, [ h('span', { 'class': 't' }, fmt(e.t)), h('span', {}, text) ]);
			}) : h('div', { 'class': 'note' }, 'Событий пока нет — значит, всё работает.'))
		]));
	}

	function head() {
		return h('div', { 'class': 'head' }, [
			h('img', { src: 'logo.png', alt: 'SkyrimVPN' }),
			h('div', {}, [
				h('div', { 'class': 'brand' }, 'SkyrimVPN'),
				h('div', { 'class': 'sub' }, 'VPN для всей домашней сети')
			]),
			h('div', { 'class': 'links' }, [
				ext(LINKS.bot, 'Бот', 'btn small'),
				ext(LINKS.support, 'Поддержка', 'btn small'),
				h('button', { 'class': 'btn small icon', title: 'Выйти', 'aria-label': 'Выйти', html: ICON.logout, onclick: logout })
			])
		]);
	}

	function paintHero() {
		var st = S.st, busy = !!st.busy;
		var on = st.enabled && st.running, broken = st.enabled && !st.running && !busy;
		var power = h('div', {
			'class': 'power' + (on ? ' on' : '') + (broken ? ' warn' : '') + (busy ? ' busy' : ''),
			role: 'button', tabindex: '0', title: st.enabled ? 'Выключить VPN' : 'Включить VPN', html: ICON.power,
			// включён, но не работает — нажатие перезапускает; иначе переключает
			onclick: function () {
				if (S.st.busy) return;
				var want = (S.st.enabled && !S.st.running) ? true : !S.st.enabled;
				act(call('toggle', { on: want }));
			}
		});

		var title, sub;
		if (busy) { title = st.busy; sub = 'Это займёт до минуты'; }
		else if (on) { title = 'VPN включён'; sub = 'Вся домашняя сеть под защитой'; }
		else if (broken) { title = 'VPN не работает'; sub = 'Выберите другой сервер или нажмите, чтобы перезапустить'; }
		else { title = 'VPN выключен'; sub = 'Интернет идёт напрямую'; }

		var srv = S.servers.filter(function (s) { return s.id === st.server_id; })[0];
		var name = st.server_name || '';
		var ipText = !on ? '—' : (S.ip || 'проверяю…');

		box.hero.replaceChildren(h('div', { 'class': 'card hero' }, [
			h('div', {}, [ power, h('div', { 'class': 'state' }, [ title, h('small', {}, sub) ]) ]),
			h('div', {}, [
				row('Сервер', name ? [ flagCode(name) ? h('span', { 'class': 'cc' }, flagCode(name)) : '', cleanName(name) ] : '—'),
				row('Протокол', srv ? protoLabel(srv) : '—'),
				row('Ваш IP в интернете', ipText),
				row('Российские сайты', 'напрямую, без VPN'),
				row('Серверов в подписке', String(st.servers || 0))
			])
		]));
	}

	function row(k, v) { return h('div', { 'class': 'row' }, [ h('span', {}, k), h('span', {}, v) ]); }

	function loadIp() {
		if (!(S.st.enabled && S.st.running)) return;
		call('ip').then(function (r) {
			S.ip = r.ip ? r.ip + (r.country ? ' · ' + r.country : '') : 'не удалось узнать';
			paintHero();
		}).catch(function () {});
	}

	function paintSub() {
		var st = S.st, exp = parseExpire(st.expire), daysEl, bar = 0;
		if (exp) {
			var days = Math.ceil((exp - new Date()) / 86400000);
			bar = Math.max(0, Math.min(100, days / 365 * 100));
			daysEl = h('div', { 'class': 'big' }, days > 0
				? [ String(days), h('small', {}, plural(days, 'день', 'дня', 'дней') + ' · до ' + exp.toLocaleDateString('ru-RU')) ]
				: [ 'Закончилась', h('small', {}, 'продлите в боте') ]);
		} else {
			daysEl = h('div', { 'class': 'big' }, [ '—', h('small', {}, 'появится после обновления') ]);
		}
		var traffic = (!st.traffic || /^0(\.0+)?\s*B$/i.test(st.traffic)) ? 'Безлимит' : st.traffic;

		var input = h('input', { 'class': 'input', type: 'url', inputmode: 'url', placeholder: 'https://… ссылка из бота', autocomplete: 'off', spellcheck: 'false' });
		var save = function () {
			var v = input.value.trim();
			if (!/^https?:\/\/\S+$/.test(v)) return toast('Вставьте ссылку из бота: «Подписка» → «Скопировать ссылку»', true);
			act(call('set_sub', { url: v }));
			input.value = ''; inputRow.classList.add('hidden');
		};
		var inputRow = h('div', { 'class': 'inputrow hidden' }, [ input, h('button', { 'class': 'btn solid', onclick: save }, 'Сохранить') ]);
		input.addEventListener('keydown', function (e) { if (e.key === 'Enter') save(); });

		box.sub.replaceChildren(h('div', { 'class': 'card' }, [
			h('h3', {}, 'Подписка'),
			h('div', { 'class': 'grid2' }, [
				h('div', {}, [ h('div', { 'class': 'sub' }, 'Осталось'), daysEl ]),
				h('div', {}, [ h('div', { 'class': 'sub' }, 'Трафик'), h('div', { 'class': 'big' }, traffic) ])
			]),
			h('div', { 'class': 'bar' }, h('i', { style: 'width:' + bar + '%' })),
			h('div', { 'class': 'actions' }, [
				h('button', { 'class': 'btn', disabled: !!st.busy, onclick: function () { act(call('update_sub')); } }, 'Обновить подписку'),
				h('button', { 'class': 'btn', onclick: function () { inputRow.classList.toggle('hidden'); input.focus(); } }, 'Сменить ссылку'),
				ext(LINKS.bot, 'Продлить в боте', 'btn solid')
			]),
			inputRow,
			h('div', { 'class': 'note' }, 'Подписка обновляется сама каждые ' + (st.sub_hours || 4) + ' ч.')
		]));
	}

	function banner() {
		return h('div', { 'class': 'banner' }, [
			h('img', { src: 'dragon.png', alt: '' }),
			h('div', { 'class': 'eyebrow' }, 'SkyrimVPN'),
			h('h2', {}, 'Защитите и телефон — даже при белых списках'),
			h('p', {}, 'Роутер защищает дом, а SkyrimVPN в телефоне работает и на мобильном интернете, когда открыты только «разрешённые» сайты. Нейросети и YouTube без ограничений, 50+ стран.'),
			h('div', { 'class': 'tags' }, [ 'Android', 'iOS', 'Windows', 'macOS', '3 дня бесплатно' ].map(function (t) { return h('span', {}, t); })),
			h('div', { 'class': 'actions' }, [
				ext(LINKS.bot, 'Открыть бота', 'btn solid'),
				ext(LINKS.bot, 'Пригласить друга: +7 дней', 'btn')
			])
		]);
	}

	function paintServers() {
		var st = S.st;
		var chips = [ [ 'all', 'Все' ], [ 'fast', 'Быстрые' ], [ 'gemini', 'Gemini' ], [ 'mobile', 'Мобильные' ], [ 'game', 'Игровые' ], [ 'torrent', 'Торренты' ] ];
		var list = S.servers.filter(function (s) { return S.filter === 'all' || cats(s.name).indexOf(S.filter) >= 0; });
		var locked = !!st.busy || S.testing;

		var rows = list.map(function (s) {
			var c = cats(s.name), ms = S.ms[s.id], cur = s.id === st.server_id, msEl;
			if (ms === 'wait') msEl = h('span', { 'class': 'ms' }, '…');
			else if (ms === '') msEl = h('span', { 'class': 'ms bad' }, 'нет ответа');
			else if (ms) msEl = h('span', { 'class': 'ms good' }, ms + ' мс');
			else msEl = h('span', { 'class': 'ms' });
			return h('div', {
				'class': 'srv' + (cur ? ' cur' : ''), role: 'button', tabindex: '0',
				onclick: function () {
					if (cur) return;
					if (S.st.busy) return toast('Подождите, роутер занят: ' + S.st.busy, true);
					act(call('set_server', { id: s.id }));
				}
			}, [
				h('span', { 'class': 'cc' }, flagCode(s.name) || '··'),
				h('span', { 'class': 'n' }, cleanName(s.name)),
				c.indexOf('gemini') >= 0 ? h('span', { 'class': 'tag gem', title: 'На этом сервере работает Gemini' }, 'Gemini') : '',
				h('span', { 'class': 'tag' }, protoLabel(s)),
				msEl,
				cur ? h('span', { 'class': 'badge' }, 'Подключено') : ''
			]);
		});

		box.srv.replaceChildren(h('div', { 'class': 'card' }, [
			h('div', { 'class': 'srvhead' }, [
				h('h3', {}, 'Серверы · ' + S.servers.length),
				h('button', { 'class': 'btn small', disabled: locked, onclick: function () { act(call('auto')); } }, 'Подобрать быстрый'),
				h('button', { 'class': 'btn small', disabled: locked, onclick: function () { testAll(list); } }, S.testing ? 'Проверяю…' : 'Проверить скорость')
			]),
			h('div', { 'class': 'chips' }, chips.map(function (c) {
				return h('button', { 'class': 'chip' + (S.filter === c[0] ? ' on' : ''), onclick: function () { S.filter = c[0]; paintServers(); } }, c[1]);
			})),
			h('div', { 'class': 'list' }, rows.length ? rows : h('div', { 'class': 'note' }, 'Таких серверов в подписке нет.')),
			h('div', { 'class': 'note' }, 'Нажмите на сервер, чтобы подключиться. «Gemini» — на сервере работает Gemini. «Мобильные» нужны для мобильного интернета с белыми списками, дома берите «Быстрые».')
		]));
	}

	function testAll(list) {
		if (S.testing) return;
		S.testing = true;
		list.forEach(function (s) { S.ms[s.id] = 'wait'; });
		paintServers();
		var i = 0;
		(function next() {
			if (i >= list.length) { S.testing = false; paintServers(); return; }
			var s = list[i++];
			call('test', { id: s.id }).then(function (r) { S.ms[s.id] = r.ms || ''; }, function () { S.ms[s.id] = ''; })
				.then(function () { paintServers(); next(); });
		})();
	}

	function foot() {
		return h('div', { 'class': 'foot' }, [
			ext(LINKS.bot, 'Бот @SkyrimVPN_bot'),
			ext(LINKS.support, 'Поддержка'),
			ext(LINKS.site, 'Сайт'),
			ext(LINKS.channel, 'Канал'),
			h('button', { onclick: report }, 'Отчёт для поддержки'),
			h('a', { href: '/cgi-bin/luci/admin/services/passwall2' }, 'Расширенные настройки'),
			h('a', { href: '/cgi-bin/luci/' }, 'Настройки роутера')
		]);
	}

	function report() {
		call('report').then(function (r) {
			var ta = h('textarea', { readonly: true }, r.text || '');
			var close = function () { m.remove(); };
			var m = h('div', { 'class': 'modal', onclick: function (e) { if (e.target === m) close(); } }, h('div', { 'class': 'card' }, [
				h('h3', {}, 'Отчёт для поддержки'),
				h('p', { 'class': 'sub' }, 'Ссылки на подписку, ключи и IP-адреса из отчёта убраны. Скопируйте его и отправьте в поддержку.'),
				ta,
				h('div', { 'class': 'actions', style: 'margin-top:12px' }, [
					h('button', { 'class': 'btn solid', onclick: function () {
						ta.select();
						var okCopy = false;
						try { okCopy = document.execCommand('copy'); } catch (e) {}
						if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(ta.value).catch(function () {});
						toast(okCopy ? 'Скопировано' : 'Выделите текст и скопируйте вручную');
					} }, 'Скопировать'),
					ext(LINKS.support, 'Открыть поддержку', 'btn'),
					h('button', { 'class': 'btn', onclick: close }, 'Закрыть')
				])
			]));
			document.body.appendChild(m);
		}).catch(failed);
	}

	/* ---------- действия и обновление ---------- */

	function act(p) {
		p.then(function (r) {
			if (r && r.ok === false) return toast(r.error || 'Не получилось', true);
			S.st.busy = S.st.busy || 'Выполняю…';
			S.wasBusy = true;
			paint();
			schedule(1500);
		}).catch(failed);
	}

	function schedule(ms) {
		clearTimeout(S.timer);
		S.timer = setTimeout(refresh, ms || (S.st.busy ? 2500 : 15000));
	}

	function refresh() {
		if (document.hidden) return schedule(5000);   // вкладка свёрнута — не нагружаем роутер
		call('status').then(function (st) {
			var busyNow = !!st.busy, done = S.wasBusy && !busyNow;
			var changed = st.server_id !== S.st.server_id || st.servers !== S.st.servers;
			S.st = st;
			if (busyNow) S.wasBusy = true;
			var next = (done || changed) ? call('servers').then(function (r) { S.servers = r.servers || []; }) : Promise.resolve();
			return next.then(function () {
				if (done) {
					S.wasBusy = false; S.ip = null;
					if (st.last) toast(st.last.replace(/^[✔✖!]\s*/, ''), /^✖/.test(st.last));
					loadIp();
				}
				loadEvents();
				paint();
				schedule();
			});
		}).catch(function (e) { if (!(e instanceof NeedLogin)) schedule(5000); });
	}

	document.addEventListener('visibilitychange', function () { if (!document.hidden && S.sid && box.hero) refresh(); });

	if (S.sid) start(); else showLogin();
})();
