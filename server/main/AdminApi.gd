extends Node

# 无头模式下的 HTTP 管理 API（极简 HTTP/1.1，基于 TCPServer）。
# 端点（端口/令牌见 server.cfg 的 admin_api_port / admin_api_token）：
#   GET  /admins                      列出管理员
#   POST /admin?user=NAME&level=N     设/移除管理员（level=0 移除）
#   POST /announce?text=MSG           发布公告（全服系统消息 + 存 MOTD）
#   GET  /status                      在线人数
# 鉴权：配置了 admin_api_token 时，需带 ?token=...（或 Authorization: Bearer ...）。
# 示例：curl -X POST "http://127.0.0.1:9080/admin?user=gm&level=3&token=XXX"

var console: Node = null
var server := TCPServer.new()
var token: String = ""
var _clients: Array = []

func setup(p_console: Node) -> void:
	console = p_console
	var port: int = 9080
	var bind_addr: String = "0.0.0.0"
	var cf := ConfigFile.new()
	if cf.load("res://server.cfg") == OK:
		if cf.has_section_key("server", "admin_api_port"):
			port = int(cf.get_value("server", "admin_api_port"))
		if cf.has_section_key("server", "admin_api_token"):
			token = String(cf.get_value("server", "admin_api_token"))
		if cf.has_section_key("server", "admin_api_bind"):
			bind_addr = String(cf.get_value("server", "admin_api_bind"))
	var err := server.listen(port, bind_addr)
	if err != OK:
		push_error("[AdminApi] 监听 %s:%d 失败（错误码 %d）。" % [bind_addr, port, err])
		return
	print("[AdminApi] HTTP 管理 API 监听 %s:%d%s" % [bind_addr, port, "" if token != "" else "（警告：未设 admin_api_token，任何人可调用！）"])

func _process(_delta: float) -> void:
	if not server.is_listening():
		return
	while server.is_connection_available():
		_clients.append({"peer": server.take_connection(), "buf": PackedByteArray()})
	for i in range(_clients.size() - 1, -1, -1):
		var c: Dictionary = _clients[i]
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.remove_at(i)
			continue
		var n: int = peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_data(n)
			if int(got[0]) == OK:
				(c["buf"] as PackedByteArray).append_array(got[1])
		var s: String = (c["buf"] as PackedByteArray).get_string_from_utf8()
		var he: int = s.find("\r\n\r\n")
		if he == -1:
			continue
		var head: String = s.substr(0, he)
		var body: String = s.substr(he + 4)
		if body.length() < _content_len(head):
			continue
		var resp: String = _handle(head, body)
		peer.put_data(resp.to_utf8_buffer())
		peer.disconnect_from_host()
		_clients.remove_at(i)

func _content_len(head: String) -> int:
	for line: String in head.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			return int(line.substr(line.find(":") + 1).strip_edges())
	return 0

func _header(head: String, name: String) -> String:
	for line: String in head.split("\r\n"):
		if line.to_lower().begins_with(name.to_lower() + ":"):
			return line.substr(line.find(":") + 1).strip_edges()
	return ""

func _parse_query(qs: String) -> Dictionary:
	var out: Dictionary = {}
	for pair: String in qs.split("&", false):
		var kv: PackedStringArray = pair.split("=")
		if kv.size() >= 1 and kv[0] != "":
			out[kv[0].uri_decode()] = (kv[1].uri_decode() if kv.size() >= 2 else "")
	return out

func _handle(head: String, body: String) -> String:
	var first: String = head.split("\r\n")[0]
	var parts: PackedStringArray = first.split(" ")
	if parts.size() < 2:
		return _resp(400, {"ok": false, "msg": "bad request"})
	var target: String = parts[1]
	var path: String = target
	var query: String = ""
	var qi: int = target.find("?")
	if qi != -1:
		path = target.substr(0, qi)
		query = target.substr(qi + 1)
	var q: Dictionary = _parse_query(query)
	# 表单 body 也并入参数。
	if body != "":
		for k: String in _parse_query(body).keys():
			q[k] = _parse_query(body)[k]
	# 鉴权
	if token != "":
		var supplied: String = String(q.get("token", ""))
		var auth: String = _header(head, "authorization")
		if auth.begins_with("Bearer "):
			supplied = auth.substr(7)
		if supplied != token:
			return _resp(401, {"ok": false, "msg": "unauthorized"})
	match path:
		"/admins":
			return _resp(200, {"ok": true, "admins": console.op_list_admins()})
		"/admin":
			var r: Dictionary = console.op_set_admin(String(q.get("user", "")), String(q.get("level", "0")).to_int())
			return _resp(200 if bool(r["ok"]) else 400, r)
		"/announce":
			var r2: Dictionary = console.op_announce(String(q.get("text", "")))
			return _resp(200 if bool(r2["ok"]) else 400, r2)
		"/status", "/":
			return _resp(200, {"ok": true, "online": Net.authed_ids().size()})
		_:
			return _resp(404, {"ok": false, "msg": "not found"})

func _resp(code: int, obj: Dictionary) -> String:
	var body: String = JSON.stringify(obj)
	var status: String = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"}.get(code, "OK")
	return "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [code, status, body.to_utf8_buffer().size(), body]
