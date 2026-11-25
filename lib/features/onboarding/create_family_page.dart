import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/cloud/cloud_api.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';

/// 创建家庭：服务端生成 6 位家庭码，并顺带签发家长 token。
class CreateFamilyPage extends StatefulWidget {
  const CreateFamilyPage({super.key});

  @override
  State<CreateFamilyPage> createState() => _CreateFamilyPageState();
}

class _CreateFamilyPageState extends State<CreateFamilyPage> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final state = AppStateScope.read(context);

    // 家庭码现在由服务端生成，建家庭变成一次网络请求，会失败。
    // 失败必须让用户看见并可以重试，不能静默留在原地转圈。
    Family family;
    try {
      family = await state.createFamily(name: _controller.text);
    } on CloudException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _showCodeDialog(family.code);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _showCodeDialog(String code) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('家庭创建好了'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('家庭码',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.seed.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                code,
                style: TextStyle(
                  fontSize: 26,
                  letterSpacing: 6,
                  fontWeight: FontWeight.w700,
                  color: AppColors.seed,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '孩子端输入自己的名字就能进入。如果家里有两个孩子重名，会用到这串码来区分。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
            },
            child: const Text('复制'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(88, 40),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _join() async {
    final ctrl = TextEditingController();
    var busy = false;
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('用家庭码接入'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontSize: 20, letterSpacing: 4),
                decoration: InputDecoration(
                  hintText: '6 位家庭码',
                  counterText: '',
                  errorText: error,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '换手机或重装后，用原来的家庭码就能接回已有作业。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() {
                        busy = true;
                        error = null;
                      });
                      final err = await AppStateScope.read(ctx).joinFamily(ctrl.text);
                      if (!ctx.mounted) return;
                      if (err == null) {
                        Navigator.pop(ctx, true);
                      } else {
                        setLocal(() {
                          busy = false;
                          error = err;
                        });
                      }
                    },
              child: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.onAccent),
                    )
                  : const Text('接入'),
            ),
          ],
        ),
      ),
    );

    if (ok == true && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创建家庭')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            '先给家里起个名字',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '比如「小宇家」。之后在设置里可以随时添加孩子。',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _controller,
            maxLength: 20,
            decoration: const InputDecoration(
              labelText: '家庭名称',
              hintText: '例如：小宇家',
              counterText: '',
            ),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: _busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.onAccent),
                  )
                : const Text('创建'),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: _busy ? null : _join,
              child: const Text(
                '我已经有家庭码，接入已有家庭',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
