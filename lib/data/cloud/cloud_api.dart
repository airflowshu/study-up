import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'cloud_config.dart';

/// 云端调用失败。message 是给用户看的中文，detail 留给日志。
///
/// [status] 让上层能区分「家庭码不对」（404）和「网络断了」——
/// 用户看到的提示完全不同，混成一个就变成"登录失败，请重试"这种废话。
class CloudException implements Exception {
  CloudException(
    this.message, {
    this.detail,
    this.status,
    this.authMissing = false,
  });
  final String message;
  final String? detail;
  final int? status;

  /// 本地已经没有可用会话（token 缺失，或 refresh 被服务端明确拒绝）。
  ///
  /// 与 [status] 分开记：这种情况请求根本没发出去，`status` 是空的。
  /// 上层据此决定是「等网络恢复」还是「该重新登录了」——
  /// 两者不能混，否则用户会对着一条永远点不掉的红条干瞪眼。
  final bool authMissing;

  bool get isNotFound => status == 404;
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'CloudException($message${detail == null ? '' : ': $detail'})';
}

/// 刷新会话的三种结果。
///
/// - [ok]：换到新 token
/// - [rejected]：服务端明确不认这个 refresh token，本地会话作废
/// - [transient]：网络断了或服务端临时出错，token 原样保留，下次再试
enum _RefreshOutcome { ok, rejected, transient }

/// 登录结果。家庭信息按原样透传给上层，由 app_state 组装成本地模型。
class AuthResult {
  AuthResult({required this.family, this.child});
  final Map<String, dynamic> family;
  final Map<String, dynamic>? child;
}

/// 自托管后端客户端。
///
/// 协议沿用迁云之前那套（PostgREST 语法 + 对象存储路径），
/// 但鉴权从「匿名 token」换成了「家庭级 token」：
///
/// - 登录  POST {base}/auth/v1/families        建家庭
///         POST {base}/auth/v1/signin/family   家长凭家庭码
///         POST {base}/auth/v1/signin/child    孩子凭家庭码 + 姓名
/// - 数据  GET/POST/PATCH/DELETE {rest}/<table>
/// - 图片  POST {base}/v1/storages/object/homework/<key>
///
/// token 里带着 family_id，服务端据此注入隔离条件，
/// 客户端传的 family_id 一律被丢弃——所以本地再怎么改也读不到别人家。
class CloudApi {
  CloudApi._();
  static final CloudApi instance = CloudApi._();

  static const _kToken = 'cb_token';
  static const _kRefreshToken = 'cb_refresh_token';
  static const _kExpireAt = 'cb_expire_at';
  static const _kDeviceId = 'cb_device_id';

  String? _token;
  String? _refreshToken;
  int _expireAt = 0;
  String _deviceId = '';
  bool _loaded = false;
  Future<bool>? _authInFlight;

  /// 全进程共用一个 HTTP 客户端，**连接会复用**。
  ///
  /// 之前用的是 `Request.send()`，那是顶层函数：每调一次就新建一个 Client，
  /// 发完立刻 close，等于每个请求都要重新走 DNS + TCP + TLS 握手。
  /// 这套服务跑在 Cloudflare Tunnel 上、隧道出口在洛杉矶，一次新建连接
  /// 实测 1.7 秒，复用连接只要 0.55 秒 —— 启动时四五个请求串起来就是
  /// 七八秒的空白等待。改成单例后只有第一个请求付握手成本。
  ///
  /// 不要在每次请求后 close，也不要换成 `http.get()` 之类的便捷函数，
  /// 它们内部同样是「一次一个 Client」。
  final http.Client _http = http.Client();

  /// 上一次请求是否因网络问题失败，用于界面上区分「没网」和「服务异常」
  bool lastErrorWasNetwork = false;

  /// 会话彻底失效时的回调。由 app_state 挂上去，负责清角色、回登录页。
  void Function()? onAuthLost;

  // ---- 本次运行的网络账本 ----
  // 用来回答「到底耗不耗流量」：设置页直接显示次数和上下行字节。
  // 只在进程内存里累加，不落盘，重启归零。
  int requestCount = 0;
  int bytesOut = 0;
  int bytesIn = 0;

  void resetStats() {
    requestCount = 0;
    bytesOut = 0;
    bytesIn = 0;
  }

  /// 图片走独立通道（带磁盘缓存），在这里单独记账，
  /// 否则设置页看到的流量会漏掉最大的一块。
  void countImageDownload(int bytes) {
    requestCount++;
    bytesIn += bytes;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_kToken);
    _refreshToken = prefs.getString(_kRefreshToken);
    _expireAt = prefs.getInt(_kExpireAt) ?? 0;
    var deviceId = prefs.getString(_kDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4().replaceAll('-', '');
      await prefs.setString(_kDeviceId, deviceId);
    }
    _deviceId = deviceId;
    _loaded = true;
  }

  Future<void> _saveSession(Map<String, dynamic> json) async {
    _token = json['access_token'] as String?;
    _refreshToken = json['refresh_token'] as String?;
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 43200;
    _expireAt = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, _token ?? '');
    await prefs.setString(_kRefreshToken, _refreshToken ?? '');
    await prefs.setInt(_kExpireAt, _expireAt);
  }

  Future<void> _clearSession() async {
    _token = null;
    _refreshToken = null;
    _expireAt = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kRefreshToken);
    await prefs.remove(_kExpireAt);
  }

  /// 本地是否还留着会话。启动时用它判断要不要直接进主页。
  Future<bool> hasSession() async {
    await _load();
    return (_token?.isNotEmpty ?? false) || (_refreshToken?.isNotEmpty ?? false);
  }

  /// 保证有可用 token。
  ///
  /// 拿不到**不再自动匿名登录**——那条路在新服务端上不存在了。
  /// 返回 false 表示"这台设备还没登录过或会话已失效"，由上层引导去登录页。
  Future<bool> ensureAuth() {
    final inFlight = _authInFlight;
    if (inFlight != null) return inFlight;
    final f = _ensureAuthInner().whenComplete(() => _authInFlight = null);
    _authInFlight = f;
    return f;
  }

  Future<bool> _ensureAuthInner() async {
    await _load();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_token != null && _token!.isNotEmpty && now < _expireAt - 60000) {
      return true;
    }
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      lastErrorWasNetwork = false;
      _refreshOutcome = _RefreshOutcome.rejected;
      return false;
    }
    final outcome = await _refresh();
    return outcome == _RefreshOutcome.ok;
  }

  /// 上一次 `ensureAuth()` 为什么失败。
  ///
  /// 上层用它区分「该等网络」还是「该重新登录」，不要直接读 [lastErrorWasNetwork]——
  /// 那个字段只反映最近一次请求，可能被别的调用覆盖。
  bool get lastAuthFailureWasNetwork =>
      _refreshOutcome == _RefreshOutcome.transient && lastErrorWasNetwork;

  // ---------------- 登录 ----------------

  /// 建一个新家庭。家庭码由服务端生成，保证唯一，客户端不再自己算。
  Future<AuthResult> createFamily(String name) async {
    final body = await _postPublic(
      '/auth/v1/families',
      {'name': name},
    );
    await _saveSession(body);
    return AuthResult(
      family: (body['family'] as Map).cast<String, dynamic>(),
    );
  }

  /// 家长凭家庭码登录。
  Future<AuthResult> signInFamily(String code) async {
    final body = await _postPublic(
      '/auth/v1/signin/family',
      {'code': code.trim().toUpperCase()},
    );
    await _saveSession(body);
    return AuthResult(
      family: (body['family'] as Map).cast<String, dynamic>(),
    );
  }

  /// 孩子凭家庭码 + 姓名登录。
  ///
  /// 家庭码不再是"重名时才要"的可选项：服务端要知道是哪个家庭才能校验姓名，
  /// 也才能签发只含该家庭范围的 token。
  Future<AuthResult> signInChild(String code, String name) async {
    final body = await _postPublic(
      '/auth/v1/signin/child',
      {'code': code.trim().toUpperCase(), 'name': name.trim()},
    );
    await _saveSession(body);
    return AuthResult(
      family: (body['family'] as Map).cast<String, dynamic>(),
      child: (body['child'] as Map).cast<String, dynamic>(),
    );
  }

  /// 退出登录。先清本地再通知服务端——用户点了退出就必须退出去。
  Future<void> signOut() async {
    await _load();
    final refreshToken = _refreshToken;
    await _clearSession();
    if (refreshToken == null || refreshToken.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse('${CloudConfig.baseUrl}/auth/v1/signout'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // 网络问题不影响本地退出
    }
  }

  Future<Map<String, dynamic>> _postPublic(
    String path,
    Map<String, dynamic> body,
  ) async {
    await _load();
    final encoded = jsonEncode(body);

    late http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('${CloudConfig.baseUrl}$path'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'x-device-id': _deviceId,
              'Accept': 'application/json',
            },
            body: encoded,
          )
          .timeout(const Duration(seconds: 20));
      requestCount++;
      bytesOut += utf8.encode(encoded).length;
      bytesIn += res.bodyBytes.length;
      lastErrorWasNetwork = false;
    } catch (e) {
      lastErrorWasNetwork = true;
      throw CloudException('连不上服务，检查一下网络或服务器是否在运行', detail: '$e');
    }

    if (res.statusCode >= 400) {
      throw CloudException(
        _errorMessage(res),
        detail: utf8.decode(res.bodyBytes, allowMalformed: true),
        status: res.statusCode,
      );
    }

    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map) {
      throw CloudException('服务返回了无法识别的内容');
    }
    return decoded.cast<String, dynamic>();
  }

  String _errorMessage(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['message'] != null) return '${body['message']}';
    } catch (_) {
      // 错误体不是 JSON 就用状态码提示
    }
    return '云端返回 ${res.statusCode}';
  }

  /// 刷新一次会话的结果。
  ///
  /// 必须三态：早前只有 true/false，于是「服务端 502」「隧道抖了一下」
  /// 和「refresh token 已失效」被当成同一件事，都会把本地会话删掉——
  /// 用户明明登录着，却因为一次网关错误被永久踢成未登录，且再也登不回来。
  _RefreshOutcome _refreshOutcome = _RefreshOutcome.rejected;

  Future<_RefreshOutcome> _refresh() async {
    final token = _refreshToken;
    if (token == null || token.isEmpty) {
      _refreshOutcome = _RefreshOutcome.rejected;
      lastErrorWasNetwork = false;
      return _RefreshOutcome.rejected;
    }
    try {
      final res = await http
          .post(
            Uri.parse('${CloudConfig.baseUrl}/auth/v1/token'),
            headers: {
              'Content-Type': 'application/json',
              'x-device-id': _deviceId,
            },
            body: jsonEncode({
              'grant_type': 'refresh_token',
              'refresh_token': token,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is! Map || body['access_token'] == null) {
          // 200 但内容不对：服务端实现有问题，留着会话下次再试，
          // 别因为一次畸形响应就把用户登出
          lastErrorWasNetwork = false;
          _refreshOutcome = _RefreshOutcome.transient;
          return _refreshOutcome;
        }
        await _saveSession(body.cast<String, dynamic>());
        lastErrorWasNetwork = false;
        _refreshOutcome = _RefreshOutcome.ok;
        return _refreshOutcome;
      }

      // 只有服务端明确说「这个 refresh token 不认」才算会话失效。
      // 5xx / 429 / 网关 502 都属于临时故障：token 留着，等下一轮再刷。
      final rejected = res.statusCode == 400 ||
          res.statusCode == 401 ||
          res.statusCode == 403;
      if (rejected) {
        await _clearSession();
        lastErrorWasNetwork = false;
        _refreshOutcome = _RefreshOutcome.rejected;
        return _refreshOutcome;
      }
      lastErrorWasNetwork = false;
      _refreshOutcome = _RefreshOutcome.transient;
      return _refreshOutcome;
    } catch (e) {
      // 超时 / 连不上：这是网络问题，不是登录失效。
      // 置位 lastErrorWasNetwork，上层才会显示「连不上网」而不是「还没登录」。
      lastErrorWasNetwork = true;
      _refreshOutcome = _RefreshOutcome.transient;
      return _refreshOutcome;
    }
  }

  /// 统一发请求。401 时先试一次 refresh，还不行就判定会话失效。
  Future<http.Response> _send(
    String method,
    Uri uri, {
    Object? jsonBody,
    List<int>? rawBody,
    Map<String, String>? extraHeaders,
    bool allowRetry = true,
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (!await ensureAuth()) {
      if (lastAuthFailureWasNetwork) {
        throw CloudException('连不上网，稍后自动重试');
      }
      throw CloudException(
        '登录已失效，请重新登录',
        authMissing: true,
      );
    }

    final headers = <String, String>{
      'x-device-id': _deviceId,
      'Accept': 'application/json',
      'Authorization': 'Bearer $_token',
      if (jsonBody != null) 'Content-Type': 'application/json; charset=utf-8',
      ...?extraHeaders,
    };

    late http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (jsonBody != null) {
        req.bodyBytes = utf8.encode(jsonEncode(jsonBody));
      } else if (rawBody != null) {
        req.bodyBytes = rawBody;
      }
      final streamed = await _http.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed);
      requestCount++;
      bytesOut += req.contentLength;
      bytesIn += res.bodyBytes.length;
      lastErrorWasNetwork = false;
    } catch (e) {
      lastErrorWasNetwork = true;
      throw CloudException('网络不稳定，稍后会自动重试', detail: '$e');
    }

    if (res.statusCode == 401 && allowRetry) {
      final outcome = await _refresh();
      if (outcome == _RefreshOutcome.ok) {
        return _send(
          method,
          uri,
          jsonBody: jsonBody,
          rawBody: rawBody,
          extraHeaders: extraHeaders,
          allowRetry: false,
          timeout: timeout,
        );
      }
      if (outcome == _RefreshOutcome.transient) {
        // 刷新时网络断了：token 还在，别把用户登出。等下一轮自动重试。
        throw CloudException('连不上网，稍后自动重试');
      }
      await _clearSession();
      onAuthLost?.call();
      throw CloudException('登录已失效，请重新登录', authMissing: true);
    }

    if (res.statusCode >= 400) {
      throw CloudException(
        _errorMessage(res),
        detail: utf8.decode(res.bodyBytes, allowMalformed: true),
        status: res.statusCode,
      );
    }

    return res;
  }

  List<Map<String, dynamic>> _asList(http.Response res) {
    if (res.bodyBytes.isEmpty) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is List) {
      return decoded.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    if (decoded is Map) return [decoded.cast<String, dynamic>()];
    return const [];
  }

  // ---------------- 表数据 ----------------

  /// 查询。query 直接用 PostgREST 语法，例如 {'child_id': 'eq.xxx'}。
  Future<List<Map<String, dynamic>>> select(
    String table, {
    Map<String, String> query = const {},
    int? limit,
  }) async {
    final params = <String, String>{...query};
    if (limit != null) params['limit'] = '$limit';
    final uri = Uri.parse('${CloudConfig.restUrl}/$table')
        .replace(queryParameters: params.isEmpty ? null : params);
    final res = await _send('GET', uri);
    return _asList(res);
  }

  /// 匿名查询。只用于 `app_releases` —— 版本检查发生在登录之前，
  /// 用户还没进家庭也得能收到更新提示。
  Future<List<Map<String, dynamic>>> selectPublic(
    String table, {
    Map<String, String> query = const {},
    int? limit,
  }) async {
    final params = <String, String>{...query};
    if (limit != null) params['limit'] = '$limit';
    final uri = Uri.parse('${CloudConfig.restUrl}/$table')
        .replace(queryParameters: params.isEmpty ? null : params);
    try {
      final res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw CloudException(_errorMessage(res));
      }
      return _asList(res);
    } catch (e) {
      if (e is CloudException) rethrow;
      throw CloudException('网络不稳定，稍后会自动重试', detail: '$e');
    }
  }

  /// 区间查询。PostgREST 对同名列的重复参数是 AND 语义
  /// （`?date=gte.2026-10-01&date=lte.2026-10-31`），
  /// 而 [select] 的 Map 表达不了重复键，所以这里直接拼查询串。
  ///
  /// [query] 必须是已经编码好的查询串，调用方自己保证值得来自可信代码。
  Future<List<Map<String, dynamic>>> selectRaw(
    String table,
    String query, {
    int? limit,
  }) async {
    final q = limit == null ? query : '$query&limit=$limit';
    final uri = Uri.parse('${CloudConfig.restUrl}/$table?$q');
    final res = await _send('GET', uri);
    return _asList(res);
  }

  /// 只改指定字段。返回被改到的行；空列表说明这条记录云端还不存在。
  Future<List<Map<String, dynamic>>> patch(
    String table,
    String id,
    Map<String, dynamic> fields,
  ) async {
    final uri = Uri.parse(
        '${CloudConfig.restUrl}/$table?id=eq.${Uri.encodeComponent(id)}');
    final res = await _send(
      'PATCH',
      uri,
      jsonBody: fields,
      extraHeaders: {'Prefer': 'return=representation'},
    );
    return _asList(res);
  }

  /// 按条件批量改。用于「删孩子时级联标记他名下所有作业」这种一次改多行的场景。
  ///
  /// [query] 是已编码好的 PostgREST 过滤串，例如 `child_id=eq.xxx`。
  /// 返回被改到的行；空列表说明没有匹配行（不算失败）。
  Future<List<Map<String, dynamic>>> patchWhere(
    String table,
    String query,
    Map<String, dynamic> fields,
  ) async {
    final uri = Uri.parse('${CloudConfig.restUrl}/$table?$query');
    final res = await _send(
      'PATCH',
      uri,
      jsonBody: fields,
      extraHeaders: {'Prefer': 'return=representation'},
    );
    return _asList(res);
  }

  /// 新增一行。主键冲突会报 409，由调用方决定是否转成 patch。
  Future<void> insert(String table, Map<String, dynamic> row) async {
    final uri = Uri.parse('${CloudConfig.restUrl}/$table');
    await _send(
      'POST',
      uri,
      jsonBody: [row],
      extraHeaders: {'Prefer': 'return=minimal'},
    );
  }

  /// 删除。业务上走软删除，这个只给「清理」用。
  Future<void> delete(String table, String id) async {
    final uri = Uri.parse(
        '${CloudConfig.restUrl}/$table?id=eq.${Uri.encodeComponent(id)}');
    await _send('DELETE', uri);
  }

  // ---------------- 图片 ----------------

  /// 上传一张图，key 形如 `f/<家庭id>/homework/<作业id>/<序号>.jpg`。
  Future<void> uploadImage(String key, List<int> bytes, String contentType) async {
    // 优先让字节从手机直进 COS。家里那条回程只有 30 KB/s 上下，
    // 1 MB 的 PDF 走 NAS 中转要 30 秒以上，40 秒的超时一撞就整条作业传不上去。
    if (await _uploadToCos(key, bytes, contentType)) return;

    final uri = Uri.parse(
        '${CloudConfig.baseUrl}/v1/storages/object/${CloudConfig.bucket}/$key');
    await _send(
      'POST',
      uri,
      rawBody: bytes,
      extraHeaders: {'Content-Type': contentType},
      // 中转这条路慢，给它足够的时间，别在半路判死
      timeout: const Duration(seconds: 180),
    );
  }

  /// 预签名直传 COS。返回 false 表示这条路不通（服务端没开 COS、签名失败、
  /// 网络抖动），调用方退回 NAS 中转。
  ///
  /// 不抛异常是有意的：直传只是快，不是唯一通路，失败了不该让整条同步失败。
  Future<bool> _uploadToCos(
    String key,
    List<int> bytes,
    String contentType,
  ) async {
    try {
      final res = await _send(
        'POST',
        Uri.parse('${CloudConfig.baseUrl}/v1/storages/presign'),
        jsonBody: {'key': key, 'content_type': contentType},
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('presign ${res.statusCode}: ${res.body}');
        return false;
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) return false;
      final uploadUrl = body['upload_url'];
      if (uploadUrl is! String || uploadUrl.isEmpty) return false;

      // Content-Type / Cache-Control 参与签名，必须原样带上
      final headers = <String, String>{'Content-Type': contentType};
      final signed = body['headers'];
      if (signed is Map) {
        signed.forEach((k, v) {
          if (k is String && v is String) headers[k] = v;
        });
      }

      final put = http.Request('PUT', Uri.parse(uploadUrl))
        ..headers.addAll(headers)
        ..bodyBytes = bytes;
      final streamed = await _http
          .send(put)
          .timeout(const Duration(seconds: 120));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
      debugPrint('cos put ${resp.statusCode}: ${resp.body}');
      return false;
    } catch (e) {
      debugPrint('cos put failed: $e');
      return false;
    }
  }

  /// 下载一张图。
  ///
  /// 之前图片是公开直链，`Image.network` 或裸 http.get 就能取；
  /// 现在仍公开读，但统一走这里是为了复用 401 重试和流量记账——
  /// 图片是流量最大的一块，漏记会让设置页的数字失真。
  Future<List<int>> downloadImage(String key) async {
    final uri = Uri.parse(CloudConfig.imageUrl(key));
    try {
      final res = await http
          .get(uri, headers: {'x-device-id': _deviceId})
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw CloudException('图片下载失败（${res.statusCode}）');
      }
      countImageDownload(res.bodyBytes.length);
      lastErrorWasNetwork = false;
      return res.bodyBytes;
    } on CloudException {
      rethrow;
    } catch (e) {
      lastErrorWasNetwork = true;
      throw CloudException('网络不稳定，稍后会自动重试', detail: '$e');
    }
  }

  /// 探活：能拿到 token 就算通。
  Future<bool> ping() async {
    try {
      return await ensureAuth();
    } catch (_) {
      return false;
    }
  }
}
