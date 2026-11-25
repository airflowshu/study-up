-- 应用安装包存储桶。
--
-- 为什么不复用 homework 桶：那个桶为了防滥用，MIME 白名单只开了
-- jpeg/png/webp/gif，单文件上限 20 MB。APK 两条都过不去
-- （application/vnd.android.package-archive 被 415 拒，release 包 49.5 MB 超限）。
-- 与其把图片桶的限制放宽——那等于让任何匿名用户都能往孩子作业的图库里
-- 塞任意二进制文件——不如单开一个桶，各自收紧各自的边界。
--
-- 权限设计的关键点：**匿名只读，不允许匿名写**。
-- homework 桶对 anon 开了 INSERT（孩子端要传作业照片，这是业务需要）。
-- 但发布目录没有这个需要：APK 只由开发方上传，走管理端凭据。
-- 如果把 apk 桶也开成匿名可写，任何人都能往你的下载目录塞一个同名文件，
-- 再把 app_releases 里的版本指过去——这是供应链攻击的入口。

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'apk',
  'apk',
  TRUE,
  104857600, -- 100 MB，足够单 ABI 和 universal 包
  ARRAY['application/vnd.android.package-archive', 'application/octet-stream', 'application/zip']
)
ON CONFLICT (id) DO UPDATE SET
  public             = TRUE,
  file_size_limit    = 104857600,
  allowed_mime_types = ARRAY['application/vnd.android.package-archive', 'application/octet-stream', 'application/zip'],
  updated_at         = now();

-- 下载：匿名与登录用户都能读（下载本来就是公开的）
DROP POLICY IF EXISTS apk_objects_read ON storage.objects;
CREATE POLICY apk_objects_read ON storage.objects
  FOR SELECT TO anon USING (bucket_id = 'apk');

DROP POLICY IF EXISTS apk_objects_read_auth ON storage.objects;
CREATE POLICY apk_objects_read_auth ON storage.objects
  FOR SELECT TO authenticated USING (bucket_id = 'apk');

-- 刻意不建 INSERT/UPDATE/DELETE 策略：上传只能走管理端凭据（service role），
-- 绕开 RLS 但会留下审计记录。客户端不该有写权限。
