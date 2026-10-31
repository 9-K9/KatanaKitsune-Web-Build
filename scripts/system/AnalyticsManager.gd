extends Node

## Privacy-first GA4 bridge for the browser build. Google handles acquisition,
## approximate geography and ordinary web sessions; this bridge adds the game
## lifecycle that cannot be inferred from a single long-lived canvas page.

const MEASUREMENT_ID := "G-LZP9EMMQKK"
const POLL_INTERVAL := 1.0

var _poll_left := 0.0
var _in_gameplay := false
var _last_floor := 0


func _ready() -> void:
	if OS.get_name() != "Web":
		process_mode = Node.PROCESS_MODE_DISABLED
		return
	_install_web_bridge()
	get_tree().scene_changed.connect(_on_scene_changed)
	call_deferred("_on_scene_changed")


func _process(delta: float) -> void:
	if not _in_gameplay:
		return
	_poll_left -= delta
	if _poll_left > 0.0:
		return
	_poll_left = POLL_INTERVAL
	var scene := get_tree().current_scene
	if scene == null or not ("depth" in scene):
		return
	var floor_number := int(scene.get("depth"))
	if floor_number != _last_floor:
		_last_floor = floor_number
		_js_call("floor", {"floor_number": floor_number})


func _on_scene_changed() -> void:
	var scene := get_tree().current_scene
	var path := scene.scene_file_path.to_lower() if scene != null else ""
	var now_gameplay := path.contains("mazedemo")
	if now_gameplay and not _in_gameplay:
		_in_gameplay = true
		_last_floor = int(scene.get("depth")) if "depth" in scene else 1
		_poll_left = 0.0
		_js_call("startGameplay", {
			"game_mode": "online" if NetworkManager.is_client else "local",
			"party_size": maxi(Roster.count(), 1),
			"floor_number": _last_floor,
		})
	elif not now_gameplay and _in_gameplay:
		_end_gameplay("scene_exit")


func end_gameplay(reason: String) -> void:
	if _in_gameplay:
		_end_gameplay(reason)


func track(event_name: String, parameters: Dictionary = {}) -> void:
	_js_call("event", {"name": event_name, "parameters": parameters})


func _end_gameplay(reason: String) -> void:
	_js_call("endGameplay", {
		"reason": reason,
		"floor_number": _last_floor,
	})
	_in_gameplay = false
	_last_floor = 0


func _js_call(method: String, payload: Dictionary) -> void:
	if OS.get_name() != "Web":
		return
	var expression := "window.kkAnalytics&&window.kkAnalytics[%s](%s)" % [
		JSON.stringify(method), JSON.stringify(payload)]
	JavaScriptBridge.eval(expression)


func _install_web_bridge() -> void:
	var javascript := """
(function () {
  if (window.kkAnalytics) return;
  const measurementId = %s;
  const consentKey = 'kk_analytics_consent';
  window.dataLayer = window.dataLayer || [];
  window.gtag = window.gtag || function () { dataLayer.push(arguments); };
  gtag('consent', 'default', {
    ad_storage: 'denied',
    ad_user_data: 'denied',
    ad_personalization: 'denied',
    analytics_storage: 'denied'
  });

  let loaded = false;
  let gameplay = null;
  const granted = () => localStorage.getItem(consentKey) === 'granted';
  const load = () => {
    if (loaded || !granted()) return;
    loaded = true;
    gtag('consent', 'update', {analytics_storage: 'granted'});
    const script = document.createElement('script');
    script.async = true;
    script.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(measurementId);
    document.head.appendChild(script);
    gtag('js', new Date());
    gtag('config', measurementId, {anonymize_ip: true});
  };
  const send = (name, parameters) => {
    if (!granted()) return;
    load();
    gtag('event', name, parameters || {});
  };
  const removeBanner = () => document.getElementById('kk-analytics-consent')?.remove();
  const choose = (choice) => {
    localStorage.setItem(consentKey, choice);
    removeBanner();
    if (choice === 'granted') load();
  };
  const showBanner = () => {
    if (localStorage.getItem(consentKey) !== null || document.getElementById('kk-analytics-consent')) return;
    const panel = document.createElement('div');
    panel.id = 'kk-analytics-consent';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', 'Analytics choice');
    panel.style.cssText = 'position:fixed;left:16px;right:16px;bottom:16px;z-index:99999;max-width:720px;margin:auto;padding:16px 18px;background:#190f13ee;color:#ffe2a8;border:1px solid #b96b32;border-radius:8px;font:15px/1.4 sans-serif;box-shadow:0 8px 30px #0009';
    panel.innerHTML = '<strong>Help improve Katana Kitsune</strong><div style="margin:7px 0 12px">Allow anonymous gameplay analytics? This measures session length, game progress, traffic source and approximate country or region. It does not collect your name or precise location.</div>';
    const decline = document.createElement('button');
    decline.textContent = 'No thanks';
    decline.style.cssText = 'padding:9px 14px;margin-right:8px;background:#2b1b20;color:#ffe2a8;border:1px solid #8e5734;border-radius:4px;cursor:pointer';
    decline.onclick = () => choose('denied');
    const accept = document.createElement('button');
    accept.textContent = 'Allow analytics';
    accept.style.cssText = 'padding:9px 14px;background:#a83e22;color:white;border:1px solid #e08b4c;border-radius:4px;cursor:pointer';
    accept.onclick = () => choose('granted');
    panel.append(decline, accept);
    document.body.appendChild(panel);
  };

  window.kkAnalytics = {
    event: ({name, parameters}) => send(name, parameters),
    startGameplay: (parameters) => {
      if (gameplay) return;
      gameplay = {started: Date.now(), floor: parameters.floor_number || 1};
      send('gameplay_start', parameters);
    },
    floor: ({floor_number}) => {
      if (gameplay) gameplay.floor = floor_number;
      send('floor_start', {floor_number});
    },
    endGameplay: ({reason, floor_number}) => {
      if (!gameplay) return;
      send('gameplay_end', {
        reason,
        floor_number: floor_number || gameplay.floor,
        duration_seconds: Math.max(1, Math.round((Date.now() - gameplay.started) / 1000)),
        transport_type: 'beacon'
      });
      gameplay = null;
    }
  };
  addEventListener('pagehide', () => window.kkAnalytics.endGameplay({reason: 'page_exit'}));
  if (granted()) load(); else showBanner();
})();
""" % JSON.stringify(MEASUREMENT_ID)
	JavaScriptBridge.eval(javascript)
