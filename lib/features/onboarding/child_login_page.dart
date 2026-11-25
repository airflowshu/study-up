import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';

/// 孩子端登录：家庭码 + 姓名。
///
/// 家庭码是必填的。以前只有重名时才要，是因为服务端不校验身份、
/// 客户端可以匿名查全表比对姓名；现在服务端要靠家庭码定位家庭并签发 token，
/// 所以第一次在设备上登录必须输一次，之后靠 refresh token 长期免登录。
class ChildLoginPage extends StatefulWidget {
  const ChildLoginPage({super.key});

  @override
  State<ChildLoginPage> createState() => _ChildLoginPageState();
}

class _ChildLoginPageState extends State<ChildLoginPage> {
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '先输入你的名字');
      return;
    }
    final code = _codeController.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() => _error = '家庭码是 6 位，在家长端「设置」页里能找到');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppStateScope.read(context);
    final result = await state.loginAsChild(name, familyCode: code);
    if (!mounted) return;
    setState(() => _busy = false);

    switch (result) {
      case LoginResult.ok:
        Navigator.of(context).popUntil((r) => r.isFirst);
      case LoginResult.notFound:
        setState(() => _error = '连不上服务，检查一下网络，或稍后再试。');
      case LoginResult.needFamilyCode:
        setState(() => _error = '请输入 6 位家庭码');
      case LoginResult.wrongCode:
        setState(() => _error = '家庭码或名字不对。家庭码是家长端设置页里那串 6 位字符。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Text(
                '你是谁',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '输入名字和家庭码，就能看到今天的作业',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 36),
              TextField(
                controller: _nameController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                style: const TextStyle(fontSize: 18),
                decoration: const InputDecoration(
                  hintText: '例如：小宇',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _codeController,
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 18, letterSpacing: 3),
                decoration: const InputDecoration(
                  labelText: '家庭码',
                  hintText: '6 位字符，问家长要',
                  counterText: '',
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: AppColors.danger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.onAccent),
                      )
                    : const Text('进入'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
