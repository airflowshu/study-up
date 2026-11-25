-- App 版本清单。
--
-- 这张表是「服务端唯一事实」：客户端只读，版本信息由发版人手工插一行。
-- 不给 anon 写权限——匿名 token 不可信，放开写等于让任何人都能把
-- 全量用户的更新地址改到自己的服务器上。
CREATE TABLE IF NOT EXISTS public.app_releases (
  id TEXT PRIMARY KEY,
  -- 目前只有 android；留着这个字段是为了以后 iOS / 小程序共用一张表
  platform TEXT NOT NULL DEFAULT 'android',
  -- 给人看的版本号，例如 1.2.0
  version_name TEXT NOT NULL,
  -- 给机器比的版本号，必须和 pubspec.yaml 里 `+` 后面的数字一致
  version_code INTEGER NOT NULL,
  -- APK 直链或下载页地址，客户端只负责打开
  download_url TEXT NOT NULL,
  -- 更新说明，换行分隔
  changelog TEXT NOT NULL DEFAULT '',
  -- true = 必须更新（弹窗没有关闭按钮）
  force_update BOOLEAN NOT NULL DEFAULT FALSE,
  -- 下架某条版本用，不删数据
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 同一平台同一个版本号只允许一条，避免列表里出现两条一模一样的可选更新
CREATE UNIQUE INDEX IF NOT EXISTS idx_app_releases_platform_code
  ON public.app_releases(platform, version_code);

-- 客户端按「平台 + 是否上架 + 版本号倒序」取第一条，走这个索引
CREATE INDEX IF NOT EXISTS idx_app_releases_lookup
  ON public.app_releases(platform, is_active, version_code DESC);

GRANT SELECT ON public.app_releases TO anon;
GRANT SELECT ON public.app_releases TO authenticated;

ALTER TABLE public.app_releases ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_read_app_releases ON public.app_releases
  FOR SELECT TO anon USING (is_active);
CREATE POLICY auth_read_app_releases ON public.app_releases
  FOR SELECT TO authenticated USING (is_active);

-- 发版示例（把 URL 换成真实地址后执行）：
--
-- INSERT INTO public.app_releases
--   (id, platform, version_name, version_code, download_url, changelog, force_update)
-- VALUES
--   ('android-1.0.1', 'android', '1.0.1', 2,
--    'https://你的域名/app/homework-1.0.1.apk',
--    E'· 新增深色模式\n· 修复离线作业偶发不自动上传', FALSE);

-- 需要紧急停用某个版本的提示时：
-- UPDATE public.app_releases SET is_active = FALSE WHERE id = 'android-1.0.1';
