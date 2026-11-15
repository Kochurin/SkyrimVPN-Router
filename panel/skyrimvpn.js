'use strict';
'require view';

/*
 * Пункт «SkyrimVPN» в меню OpenWrt: открывает отдельную панель /skyrim/
 * и передаёт ей текущий вход, чтобы не вводить пароль второй раз.
 * https://github.com/Kochurin/SkyrimVPN-Router
 */

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	render: function() {
		try { if (L.env.sessionid) localStorage.setItem('skv_sid', L.env.sessionid); } catch (e) {}
		window.location.href = '/skyrim/';
		return E('p', {}, [ 'Открываю панель SkyrimVPN… ', E('a', { href: '/skyrim/' }, 'Открыть') ]);
	}
});
