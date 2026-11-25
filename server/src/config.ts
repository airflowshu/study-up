/** 运行期配置。全部来自环境变量，容器里由 compose 注入。 */
export const config = {
  port: Number(process.env.PORT ?? 8787),
  host: '0.0.0.0',

  databaseUrl:
    process.env.DATABASE_URL ??
    'postgres://homework:homework@127.0.0.1:5432/homework',

  /** 签发 JWT 用的密钥。少于 32 字节直接拒绝启动——短密钥等于没有。 */
  jwtSecret: process.env.JWT_SECRET ?? '',

  /** 发版脚本用的后台令牌。 */
  adminToken: process.env.ADMIN_TOKEN ?? '',

  /** 上传根目录，图片落 `<DATA_DIR>/uploads/...`。 */
  dataDir: process.env.DATA_DIR ?? './data',

  /** 站点对外的根地址，用于拼 APK 下载链接。留空则用请求头推导。 */
  publicOrigin: process.env.PUBLIC_ORIGIN ?? '',

  accessTtlSec: 12 * 60 * 60,
  refreshTtlSec: 180 * 24 * 60 * 60,

  /**
   * 单个上传对象的上限 20MB，与旧 CloudBase 桶的限制保持一致。
   * 图片、PDF、DOCX 共用这一条——扫描版 PDF 偶尔会顶到这个数，
   * 超了客户端会先拦下来并提示，不会白传。
   */
  maxImageBytes: 20 * 1024 * 1024,

  /** APK 上限。 */
  maxApkBytes: 200 * 1024 * 1024,

  /**
   * 允许上传的 MIME。
   *
   * 作业正文除了图片，还支持 PDF 和 DOCX 附件（App 端 1.2 起）。
   * 以前这个集合叫 allowedImageMime，只有四种图片——那会让附件上传
   * 在服务端被直接拒掉，客户端只会看到一句「只支持 jpeg / png / webp / gif」。
   */
  allowedUploadMime: new Set([
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  ]),

  /**
   * 腾讯云 COS。图片直传用，绕开 Cloudflare 隧道（隧道落洛杉矶，上行几十 KB/s）。
   * 四项全填才启用；缺任何一项就退回到 NAS 本地存储，客户端不用改。
   */
  cos: {
    secretId: process.env.COS_SECRET_ID ?? '',
    secretKey: process.env.COS_SECRET_KEY ?? '',
    bucket: process.env.COS_BUCKET ?? '',
    region: process.env.COS_REGION ?? '',
  },
} as const

export function assertConfig(): void {
  const problems: string[] = []
  if (config.jwtSecret.length < 32) {
    problems.push('JWT_SECRET 至少 32 个字符（建议 openssl rand -hex 32）')
  }
  if (config.adminToken.length < 16) {
    problems.push('ADMIN_TOKEN 至少 16 个字符')
  }
  if (problems.length) {
    throw new Error(`配置不合法：\n  - ${problems.join('\n  - ')}`)
  }
}
