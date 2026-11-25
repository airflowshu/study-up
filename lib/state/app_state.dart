import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/theme.dart';
import '../data/cloud/cloud_api.dart';
import '../data/cloud/sync_service.dart';
import '../data/repository.dart';
import '../models/models.dart';

enum Role { none, parent, child }

enum LoginResult { ok, notFound, needFamilyCode, wrongCode }

/// 外观偏好。默认跟随系统。
enum AppThemeMode { system, light, dark }

extension AppThemeModeLabel on AppThemeMode {
  String get label => switch (this) {
        AppThemeMode.system => '跟随系统',
        AppThemeMode.light => '浅色',
        AppThemeMode.dark => '深色',
      };
}

/// 全局同步提示的类型。
///
/// 三种提示语必须各自独立：离线是「你先用着，回头我补」，
/// 失败是「云端那边出问题了」，会话失效是「你有个动作要做」——
/// 最后一种如果混进失败里，用户就会对着一条永远点不掉的红条。
enum SyncNoticeKind { offline, authLost, failed }

/// 顶部提示条要显示的内容。[AppState.syncNotice] 为 null 时什么都不显示。
class SyncNotice {
  const SyncNotice(this.kind, this.text);
  final SyncNoticeKind kind;
  final String text;
}

/// 全局状态：登录角色、家庭、孩子列表、当前查看的孩子。
/// 用 ChangeNotifier + InheritedNotifier 手动管理，不引入额外状态库。
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this._repo);

  final Repository _repo;
  static const _uuid = Uuid();

  bool ready = false;
  Role role = Role.none;
  Family? family;
  List<Child> children = [];

  /// 外观偏好，默认跟随系统。
  AppThemeMode themeMode = AppThemeMode.system;

  /// 系统层面的亮度。跟随系统模式下由它决定实际用哪套配色。
  Brightness get _platformBrightness =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  /// 当前**实际**生效的亮度。MaterialApp 和调色板都以此为准，
  /// 避免出现「Material 组件已经是深色、自己的卡片还是白的」这种割裂。
  Brightness get effectiveBrightness => switch (themeMode) {
        AppThemeMode.system => _platformBrightness,
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
      };

  /// 把当前亮度同步到调色板和系统栏。必须在 notifyListeners 之前调用。
  void _syncPalette() {
    AppColors.use(effectiveBrightness);
    applySystemOverlay();
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    if (themeMode == mode) return;
    themeMode = mode;
    await _repo.writeMeta('theme_mode', mode.name);
    _syncPalette();
    notifyListeners();
  }

  @override
  void didChangePlatformBrightness() {
    // 跟随系统时才有反应；用户显式选了浅色/深色，系统怎么变都不该动。
    if (themeMode != AppThemeMode.system) return;
    _syncPalette();
    notifyListeners();
  }

  /// 每完成一次同步自增。页面据此判断「数据可能变了，该重新读一次本地库」。
  int syncStamp = 0;

  String? _activeChildId; // 家长端当前查看的孩子
  String? _loggedChildId; // 孩子端已登录的孩子

  Child? get activeChild {
    if (_activeChildId == null) return children.isEmpty ? null : children.first;
    for (final c in children) {
      if (c.id == _activeChildId) return c;
    }
    return children.isEmpty ? null : children.first;
  }

  Child? get loggedChild {
    if (_loggedChildId == null) return null;
    for (final c in children) {
      if (c.id == _loggedChildId) return c;
    }
    return null;
  }

  bool get hasFamily => family != null;

  Future<void> init() async {
    family = await _repo.loadFamily();
    children = await _repo.children();
    final savedRole = await _repo.readMeta('role');
    if (savedRole == 'parent') role = Role.parent;
    if (savedRole == 'child') role = Role.child;
    _activeChildId = await _repo.readMeta('active_child');
    _loggedChildId = await _repo.readMeta('logged_child');
    // 外观偏好要在第一帧之前就定下来，否则启动瞬间会闪一下浅色
    final savedTheme = await _repo.readMeta('theme_mode');
    themeMode = AppThemeMode.values.firstWhere(
      (m) => m.name == savedTheme,
      orElse: () => AppThemeMode.system,
    );
    _syncPalette();
    // 服务端判定会话彻底失效（refresh 也救不回来）时，先尝试用本地家庭码
    // 静默续期——用户正在家长端布置作业，不该因为一次 401 就被弹回角色页。
    // 续不上才清身份，见 _recoverSession。
    CloudApi.instance.onAuthLost = () {
      unawaited(_recoverSession());
    };
    // 孩子端登录态失效（孩子被删了）时退回未登录
    if (role == Role.child && loggedChild == null) {
      role = Role.none;
      _loggedChildId = null;
      await _repo.deleteMeta('logged_child');
      await _repo.deleteMeta('role');
    }
    ready = true;
    notifyListeners();
    // 开机后台同步一次：家长端补传离线数据，孩子端拉最新作业
    _startAutoSync();
    unawaited(_autoSync('启动'));
  }

  // ---------------- 自动同步 ----------------

  /// 同步不该是一个需要用户点按钮的动作。这里挂三条触发线：
  ///
  /// 1. **网络从无到有** —— 断网时攒下的写入立刻补传（connectivity 监听）
  /// 2. **App 回到前台** —— 手机端最可靠的一次机会，比网络信号更实在
  /// 3. **失败后退避重试** —— 兜住「网恢复了但用户没动手机」的窗口
  ///
  /// 第 1 条依赖系统网络状态回调，而 Android 的 connectivity 只报告网卡状态、
  /// 不保证真能连通（连上一个没有出口的 WiFi 也报「已连接」），
  /// 所以第 3 条不是冗余，是必要的兜底：真的传不上去时会自己再试几次。
  static const _retryDelays = [30, 60, 120, 300, 300];

  Timer? _retryTimer;
  int _retryAttempt = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _autoSyncStarted = false;
  bool _disposed = false;

  void _startAutoSync() {
    if (_autoSyncStarted) return;
    _autoSyncStarted = true;
    WidgetsBinding.instance.addObserver(this);
    final conn = Connectivity();
    // 先取一次当前状态：启动时就已经离线的话，提示条要立刻出来，
    // 不能等用户碰到第一次失败才知道。
    unawaited(conn.checkConnectivity().then((results) {
      if (_disposed) return;
      _setNetDown(results.every((r) => r == ConnectivityResult.none));
    }));
    _connectivitySub = conn.onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      _setNetDown(!online);
      if (online) unawaited(_autoSync('网络恢复'));
    });
  }

  /// 系统层面报告「没有网络」。
  ///
  /// 它只是**必要条件**：Android 连上一个打不通的 WiFi 也会报在线，
  /// 所以真正的离线判定还要看同步请求为什么失败，见 [isOffline]。
  bool _netDown = false;

  void _setNetDown(bool down) {
    if (_netDown == down) return;
    _netDown = down;
    notifyListeners();
  }

  /// 当前是否处于「设备离线」状态。
  ///
  /// 两条来源取或：系统说没网，或者同步请求本身因为网络原因失败了。
  /// 后者更可信——请求真发出去了、真超时了，比网卡状态更能说明问题。
  bool get isOffline =>
      _netDown ||
      (SyncService.instance.phase == SyncPhase.failed &&
          SyncService.instance.lastFailureWasOffline);

  /// 顶部全局提示条的内容。null = 一切正常，不占任何版面。
  SyncNotice? get syncNotice {
    if (!ready) return null;
    if (isOffline) {
      return const SyncNotice(
        SyncNoticeKind.offline,
        '设备已离线，改动先存在本机，联网后自动同步',
      );
    }
    final sync = SyncService.instance;
    if (sync.phase == SyncPhase.failed) {
      // 会话失效排在前面：这时候提示「同步失败，稍后自动重试」是误导，
      // 再试一百次也不会成功，必须让用户看到「重新登录」这个动作。
      if (sync.lastFailureWasAuthMissing) {
        return const SyncNotice(
          SyncNoticeKind.authLost,
          '登录已失效，需重新登录才能同步',
        );
      }
      return SyncNotice(
        SyncNoticeKind.failed,
        sync.message.isEmpty ? '同步失败，稍后自动重试' : sync.message,
      );
    }
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只认 resumed：inactive 在拉通知栏、来电时都会闪一下，拿它当触发太频繁
    if (state == AppLifecycleState.resumed) {
      unawaited(_autoSync('回到前台'));
    }
  }

  /// 自动同步的统一入口。失败后自动排下一次重试。
  ///
  /// 刚同步成功过（5 秒内）就直接跳过：切前后台会连续触发 resumed，
  /// 不节流的话每次切回来都发一轮请求，纯属白耗流量。
  Future<void> _autoSync(String reason) async {
    if (_disposed || !ready) return;
    // SyncService 内部本身是串行队列，但同一条触发线重复插队没有意义
    if (SyncService.instance.phase == SyncPhase.syncing) return;
    final last = SyncService.instance.lastSuccess;
    if (last != null && DateTime.now().difference(last).inSeconds < 5) {
      _scheduleRetry();
      return;
    }
    _retryTimer?.cancel();
    await syncNow();
    if (_disposed) return;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (family == null) return; // 还没建/接入家庭，没有可同步的东西
    if (SyncService.instance.phase != SyncPhase.failed) {
      _retryAttempt = 0;
      return;
    }
    if (_retryAttempt >= _retryDelays.length) return; // 试够了，等下次前台/网络变化
    final seconds = _retryDelays[_retryAttempt];
    _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_autoSync('重试'));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _connectivitySub?.cancel();
    if (_autoSyncStarted) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  /// 建一个新家庭。
  ///
  /// 家庭码不再由客户端算：它要全局唯一，而这个约束只有数据库能保证。
  /// 服务端建行 + 生成码 + 签发 token 一次完成，这里只负责落本地。
  Future<Family> createFamily({required String name}) async {
    final auth = await CloudApi.instance.createFamily(
      name.trim().isEmpty ? '我们家' : name.trim(),
    );
    final f = Family(
      id: auth.family['id'] as String,
      code: auth.family['code'] as String,
      name: (auth.family['name'] ?? '') as String,
      createdAt: (auth.family['created_at'] as num?)?.toInt() ?? 0,
    );
    await _repo.saveFamily(f);
    family = f;
    await setRole(Role.parent);
    notifyListeners();
    SyncService.instance.markFamilyDirty();
    unawaited(syncNow());
    return f;
  }

  Future<void> setRole(Role r) async {
    role = r;
    await _repo.writeMeta('role', r.name);
    notifyListeners();
    // 「家人端身份」和「云端会话」是分开存的：孩子端退出登录会把 token 清掉，
    // 而家长从角色页切回来时只改了本地 role。这里顺手把会话补上，
    // 别等第一次同步失败才在顶部挂一条「登录已失效」。
    if (r == Role.parent) {
      unawaited(ensureCloudSession().catchError((Object _) => false));
    }
  }

  Future<void> selectChild(String childId) async {
    _activeChildId = childId;
    await _repo.writeMeta('active_child', childId);
    notifyListeners();
  }

  Future<void> refreshChildren() async {
    children = await _repo.children();
    notifyListeners();
  }

  Future<void> addChild({required String name, required int colorIndex}) async {
    if (family == null) return;
    final c = Child(
      id: _uuid.v4(),
      familyId: family!.id,
      name: name.trim(),
      colorIndex: colorIndex,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.upsertChild(c);
    children = await _repo.children();
    _activeChildId ??= c.id;
    notifyListeners();
    SyncService.instance.markFamilyDirty();
    unawaited(syncNow());
  }

  Future<void> updateChild(Child child) async {
    await _repo.upsertChild(child);
    children = await _repo.children();
    notifyListeners();
    SyncService.instance.markFamilyDirty();
    unawaited(syncNow());
  }

  Future<void> removeChild(String id) async {
    await _repo.deleteChild(id);
    children = await _repo.children();
    SyncService.instance.markFamilyDirty();
    if (_activeChildId == id) _activeChildId = children.isEmpty ? null : children.first.id;
    notifyListeners();
    unawaited(syncNow());
  }

  /// 孩子端登录：家庭码 + 姓名。
  ///
  /// 以前是「先查出所有同名孩子，再让家长补家庭码区分」——
  /// 那是因为服务端不校验身份，任何人都能匿名查全表。
  /// 现在家庭码是必填的凭证：服务端用它定位家庭、校验姓名、签发只含该家庭的 token。
  ///
  /// 代价是孩子每台新设备首次登录都要输一次 6 位码；
  /// 之后靠 refresh token 长期免登录，不用每次输。
  Future<LoginResult> loginAsChild(String name, {String? familyCode}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return LoginResult.notFound;

    final code = (familyCode ?? '').trim().toUpperCase();
    if (code.length != 6) return LoginResult.needFamilyCode;

    try {
      final auth = await CloudApi.instance.signInChild(code, trimmed);

      final f = Family(
        id: auth.family['id'] as String,
        code: auth.family['code'] as String? ?? code,
        name: (auth.family['name'] ?? '') as String,
        createdAt: (auth.family['created_at'] as num?)?.toInt() ?? 0,
      );
      await _repo.saveFamily(f);
      family = f;

      final c = Child(
        id: auth.child!['id'] as String,
        familyId: f.id,
        name: auth.child!['name'] as String,
        colorIndex: (auth.child!['color_index'] as num?)?.toInt() ?? 0,
        createdAt: (auth.child!['created_at'] as num?)?.toInt() ?? 0,
      );
      await _repo.upsertChild(c);
      children = await _repo.children();

      _loggedChildId = c.id;
      await _repo.writeMeta('logged_child', c.id);
      role = Role.child;
      await _repo.writeMeta('role', Role.child.name);
      notifyListeners();
      SyncService.instance.markFamilyDirty();
      unawaited(syncNow());
      return LoginResult.ok;
    } on CloudException catch (e) {
      // 404 有两种：家庭码不存在、这个家里没这个名字。
      // 服务端已经把话说清楚了，这里按"家庭码不对"归一类，
      // 免得给出「查无此人」这种会让家长以为孩子被删了的提示。
      if (e.isNotFound) return LoginResult.wrongCode;
      return LoginResult.notFound;
    }
  }

  Future<void> logoutChild() async {
    _loggedChildId = null;
    await _repo.deleteMeta('logged_child');
    role = Role.none;
    await _repo.deleteMeta('role');
    notifyListeners();
    // 退出即吊销服务端会话，别让旧 refresh token 一直有效
    await CloudApi.instance.signOut();
  }

  /// 家长端一键预览孩子看到的样子：直接把当前选中的孩子设为已登录。
  Future<void> switchToChildView() async {
    final c = activeChild;
    if (c == null) return;
    _loggedChildId = c.id;
    await _repo.writeMeta('logged_child', c.id);
    role = Role.child;
    await _repo.writeMeta('role', Role.child.name);
    notifyListeners();
  }

  /// 家长端进入前的校验。孩子退出后回到角色页，若可无门槛进家长端，
  /// 「只读」就形同虚设，所以这里加一道家庭码。
  Future<bool> verifyParent({required String code}) async {
    final f = family;
    if (f == null) return false;
    if (f.code.toUpperCase() != code.trim().toUpperCase()) return false;
    await _repo.writeMeta('parent_verified', '1');
    notifyListeners();
    return true;
  }

  Future<bool> get parentVerified async =>
      (await _repo.readMeta('parent_verified')) == '1';

  /// 家长端用家庭码接入一个已经存在的家庭。
  /// 换手机、重装 App 后靠这个把原来的家庭和孩子找回来，否则家长会永久锁在门外。
  Future<String?> joinFamily(String code) async {
    final upper = code.trim().toUpperCase();
    if (upper.length != 6) return '家庭码是 6 位';
    try {
      final auth = await CloudApi.instance.signInFamily(upper);
      final f = Family(
        id: auth.family['id'] as String,
        code: auth.family['code'] as String? ?? upper,
        name: (auth.family['name'] ?? '') as String,
        createdAt: (auth.family['created_at'] as num?)?.toInt() ?? 0,
      );
      await _repo.saveFamily(f);
      family = f;
      await SyncService.instance.pullChildren(f.id);
      children = await _repo.children();
      _activeChildId ??= children.isEmpty ? null : children.first.id;
      if (_activeChildId != null) {
        await _repo.writeMeta('active_child', _activeChildId!);
      }
      await setRole(Role.parent);
      notifyListeners();
      SyncService.instance.markFamilyDirty();
      // 把这台设备上看不到的作业拉回来
      unawaited(syncNow());
      return null;
    } on CloudException catch (e) {
      return e.message;
    } catch (e) {
      return '接入失败：$e';
    }
  }

  /// 打勾 / 取消打勾。先写本地立即生效，再后台把这两个字段回传云端。
  Future<void> setHomeworkDone(Homework hw, bool done) async {
    await _repo.setDone(hw.id, done);
    notifyListeners();
    // 只回写 is_done / done_at，不拉全量。打勾是最频繁的操作，
    // 每勾一次都顺手拉 500 条作业纯属浪费流量。
    unawaited(SyncService.instance.syncAll(
      isParent: false,
      childId: hw.childId,
      pull: false,
    ).then((_) => notifyListeners()));
  }

  // ---------------- 会话自愈 ----------------

  /// 本地身份（家庭码）和云端会话是两套东西：sqlite 里的 family / role
  /// 决定界面显示哪个端，SharedPreferences 里的 token 决定能不能调云端。
  /// 只要 token 因为任何原因没了（孩子端退出登录会 signOut、服务端换库、
  /// 刷新被拒），界面还是家长端，但每个请求都会被判「未登录」。
  ///
  /// 家庭码是长期有效的凭证，所以这里用它在后台静默换一个新 token，
  /// 覆盖所有入口：启动同步、切回前台、用户点提示条、从角色页进家长端。
  Future<bool>? _reloginInFlight;

  /// 静默续期失败后的退避截止时间。服务端登录接口每分钟只放 10 次，
  /// 不做退避的话，一轮同步里每个请求都去撞一次限流。
  DateTime? _reloginCooldownUntil;

  static const _reloginCooldown = Duration(seconds: 60);

  /// 确保手上有一张能用的 token。token 还有效时几乎零开销（只读内存）。
  ///
  /// [force] 用于用户主动点击的场景：明确的重试意图不该被退避拦住。
  Future<bool> ensureCloudSession({bool force = false}) async {
    if (await CloudApi.instance.ensureAuth()) return true;
    final f = family;
    if (f == null || f.code.isEmpty) return false;

    if (!force) {
      final until = _reloginCooldownUntil;
      if (until != null && DateTime.now().isBefore(until)) return false;
    } else {
      _reloginCooldownUntil = null;
    }

    final inFlight = _reloginInFlight;
    if (inFlight != null) return inFlight;
    final fut = _relogin(f).whenComplete(() => _reloginInFlight = null);
    _reloginInFlight = fut;
    return fut;
  }

  Future<bool> _relogin(Family f) async {
    try {
      if (role == Role.child) {
        // 孩子端只能签孩子 token，否则服务端会按家长权限建索引
        final c = loggedChild;
        if (c == null) return false;
        final auth = await CloudApi.instance.signInChild(f.code, c.name);
        final raw = auth.child;
        if (raw != null) {
          await _repo.upsertChild(Child(
            id: raw['id'] as String,
            familyId: (raw['family_id'] as String?) ?? f.id,
            name: raw['name'] as String,
            colorIndex: (raw['color_index'] as num?)?.toInt() ?? 0,
            createdAt: (raw['created_at'] as num?)?.toInt() ?? 0,
          ));
          children = await _repo.children();
        }
      } else {
        final auth = await CloudApi.instance.signInFamily(f.code);
        final raw = auth.family;
        final fresh = Family(
          id: raw['id'] as String,
          code: (raw['code'] as String?) ?? f.code,
          name: (raw['name'] ?? '') as String,
          createdAt: (raw['created_at'] as num?)?.toInt() ?? 0,
        );
        await _repo.saveFamily(fresh);
        family = fresh;
      }
      _reloginCooldownUntil = null;
      notifyListeners();
      return true;
    } on CloudException catch (e) {
      _reloginCooldownUntil = DateTime.now().add(_reloginCooldown);
      // 404 说明这个家庭码在服务端已经不存在（家庭被删或服务端换库），
      // 本地这份身份再也换不到 token。只有这种情况才真的需要用户重新接入。
      if (e.isNotFound) await _dropBrokenIdentity();
      return false;
    } catch (_) {
      _reloginCooldownUntil = DateTime.now().add(_reloginCooldown);
      return false;
    }
  }

  /// 会话被服务端判死后的处理：先静默续一次，续不上就原地等用户点提示条。
  ///
  /// 30 秒防抖：续期成功后紧接着的同步如果又拿到 401（服务端签发异常这类极端情况），
  /// 不加这道闸就会变成「登录 → 401 → 登录」的死循环。
  DateTime? _lastRecoverAt;

  Future<void> _recoverSession() async {
    if (!ready) return;
    final now = DateTime.now();
    final last = _lastRecoverAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastRecoverAt = now;
    if (await ensureCloudSession()) {
      unawaited(syncNow().catchError((Object _) {}));
    }
    // 续不上时不清 role：提示条会变成「登录已失效」，用户点一下就能强制重试。
    // 家庭码真的失效时，_relogin 里已经通过 _dropBrokenIdentity 清掉身份。
  }

  /// 家庭码在服务端已不存在，本地这份身份没法再用了。
  /// 保留本地作业记录（用户可能还要回看），只清身份相关的元数据。
  Future<void> _dropBrokenIdentity() async {
    await _repo.deleteMeta('family');
    await _repo.deleteMeta('role');
    await _repo.deleteMeta('logged_child');
    await _repo.deleteMeta('parent_verified');
    family = null;
    children = [];
    _activeChildId = null;
    _loggedChildId = null;
    role = Role.none;
    notifyListeners();
  }

  /// 一键同步。家长端推内容、拉孩子的打勾状态；孩子端拉作业、回传打勾。
  ///
  /// [forceRelogin] 由用户点击「重新登录 / 重试」时置 true，
  /// 用于跳过静默续期的退避窗口。
  Future<void> syncNow({bool forceRelogin = false}) async {
    // 只有明确的孩子端才走「只回写打勾」。角色为 none 时（例如家长退出登录）
    // 仍按家长处理，否则待上传的正文会被误当成完成状态推上去。
    final isParent = role != Role.child;
    final childId = isParent ? activeChild?.id : loggedChild?.id;
    if (family == null && childId == null) {
      // 还没建家庭，没有可同步的东西
      await SyncService.instance.refreshPending();
      return;
    }
    // 同步前先确保有 token：能静默续期就别去发注定 401 的请求，
    // 更别把「未登录」当成同步结果弹给用户。
    if (family != null) {
      await ensureCloudSession(force: forceRelogin);
    }
    await SyncService.instance.syncAll(
      isParent: isParent,
      childId: childId,
      family: family,
      children: children,
    );
    // 家长在另一台设备上把这个孩子删了：本机登录态必须立刻作废，
    // 否则孩子这边还能继续看到旧作业。
    if (role == Role.child && SyncService.instance.childRevoked) {
      SyncService.instance.childRevoked = false;
      await logoutChild();
      syncStamp++;
      return;
    }
    // 同步可能带来新数据，让页面重新取一次
    syncStamp++;
    notifyListeners();
  }

  Future<void> resetAll() async {
    await _repo.deleteMeta('family');
    await _repo.deleteMeta('role');
    await _repo.deleteMeta('active_child');
    await _repo.deleteMeta('logged_child');
    family = null;
    children = [];
    _activeChildId = null;
    _loggedChildId = null;
    role = Role.none;
    notifyListeners();
    // 本机清空的同时吊销服务端会话，否则那台设备上的 refresh token 还活着
    await CloudApi.instance.signOut();
  }
}

/// 用 InheritedNotifier 把状态往下传，页面里 AppStateScope.of(context) 取用。
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState state,
    required super.child,
  }) : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope 未挂载');
    return scope!.notifier!;
  }

  /// 只读取、不订阅刷新，用于回调里调用方法。
  static AppState read(BuildContext context) {
    final scope =
        context.getInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope 未挂载');
    return scope!.notifier!;
  }
}
