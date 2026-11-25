/**
 * 表契约：列白名单、列类型、各角色的读写权限。
 *
 * 这是整个后端唯一需要"按表改"的地方。查询构造器与 guard 都从这里取事实，
 * 不在路由里散落 if 判断——散落的权限判断就是越权漏洞的来源。
 */

export type Role = 'parent' | 'child'
export type ColType = 'text' | 'bigint' | 'int' | 'bool' | 'jsonb'

export interface ColumnDef {
  name: string
  type: ColType
}

export interface TableDef {
  name: string
  columns: ColumnDef[]
  /**
   * 隔离键。
   * - `family`：用 `family_id = <token.familyId>` 过滤
   * - `self`：用 `id = <token.familyId>`（families 表本身）
   * - `global`：全局表，不按家庭隔离（app_releases）
   */
  scope: 'family' | 'self' | 'global'
  /** 孩子 token 读取时是否再按 child_id 收窄（homework / homework_sessions）。 */
  childNarrow?: 'child_id' | 'id'
  /** 各角色可读列。null = 整表不可读。 */
  read: { parent: string[] | null; child: string[] | null; anon: string[] | null }
  /** 各角色可写列。null = 不可写。insert 与 patch 共用。 */
  write: { parent: string[] | null; child: string[] | null }
  /** 是否允许物理删除。业务全是软删，默认不允许。 */
  allowDelete?: boolean
  /** 匿名读取时强制的附加条件（app_releases 用）。 */
  anonWhere?: { column: string; value: unknown }
}

const col = (name: string, type: ColType): ColumnDef => ({ name, type })

export const TABLES: Record<string, TableDef> = {
  families: {
    name: 'families',
    scope: 'self',
    columns: [
      col('id', 'text'),
      col('code', 'text'),
      col('name', 'text'),
      col('created_at', 'bigint'),
    ],
    // 孩子绝对不能读 families：code 就是家长密码，
    // 孩子一旦读到就能去网页端以家长身份登录整个家庭。
    read: { parent: ['id', 'code', 'name', 'created_at'], child: null, anon: null },
    // 家庭行由服务端在 /auth/v1/families 创建，客户端不再直接写，
    // 否则客户端可以自造 code、改 name 绕过服务端校验。
    write: { parent: null, child: null },
  },

  children: {
    name: 'children',
    scope: 'family',
    childNarrow: 'id',
    columns: [
      col('id', 'text'),
      col('family_id', 'text'),
      col('name', 'text'),
      col('color_index', 'int'),
      col('created_at', 'bigint'),
      col('updated_at', 'bigint'),
      col('is_deleted', 'bool'),
    ],
    read: {
      parent: ['id', 'family_id', 'name', 'color_index', 'created_at', 'updated_at', 'is_deleted'],
      child: ['id', 'family_id', 'name', 'color_index', 'created_at'],
      anon: null,
    },
    write: {
      parent: ['id', 'family_id', 'name', 'color_index', 'created_at', 'updated_at', 'is_deleted'],
      child: null,
    },
  },

  homework: {
    name: 'homework',
    scope: 'family',
    childNarrow: 'child_id',
    columns: [
      col('id', 'text'),
      col('child_id', 'text'),
      col('family_id', 'text'),
      col('date', 'text'),
      col('subject', 'text'),
      col('content', 'text'),
      col('images', 'jsonb'),
      // 附件与链接卡片。形状：[{kind:'file'|'link', ...}]，见客户端 Attachment 模型。
      // 单独一列而不是塞进 images：两者语义不同，图片还要和正文 [图N] 按下标对齐。
      col('attachments', 'jsonb'),
      col('is_done', 'bool'),
      col('done_at', 'bigint'),
      col('created_at', 'bigint'),
      col('updated_at', 'bigint'),
      col('is_deleted', 'bool'),
    ],
    read: {
      parent: [
        'id', 'child_id', 'family_id', 'date', 'subject', 'content',
        'images', 'attachments', 'is_done', 'done_at', 'created_at',
        'updated_at', 'is_deleted',
      ],
      child: [
        'id', 'child_id', 'family_id', 'date', 'subject', 'content',
        'images', 'attachments', 'is_done', 'done_at', 'created_at',
        'updated_at', 'is_deleted',
      ],
      anon: null,
    },
    // 孩子只能改完成态。这条是产品约束（需求文档明写），
    // 以前只在客户端自律，现在由服务端强制。
    write: {
      parent: [
        'id', 'child_id', 'family_id', 'date', 'subject', 'content',
        'images', 'attachments', 'is_done', 'done_at', 'created_at',
        'updated_at', 'is_deleted',
      ],
      child: ['is_done', 'done_at'],
    },
  },

  homework_sessions: {
    name: 'homework_sessions',
    scope: 'family',
    childNarrow: 'child_id',
    columns: [
      col('id', 'text'),
      col('child_id', 'text'),
      col('family_id', 'text'),
      col('homework_id', 'text'),
      col('date', 'text'),
      col('subject', 'text'),
      col('start_at', 'bigint'),
      col('end_at', 'bigint'),
      col('seconds', 'int'),
      col('created_at', 'bigint'),
      col('updated_at', 'bigint'),
      col('is_deleted', 'bool'),
    ],
    read: {
      parent: [
        'id', 'child_id', 'family_id', 'homework_id', 'date', 'subject',
        'start_at', 'end_at', 'seconds', 'created_at', 'updated_at', 'is_deleted',
      ],
      child: [
        'id', 'child_id', 'family_id', 'homework_id', 'date', 'subject',
        'start_at', 'end_at', 'seconds', 'created_at', 'updated_at', 'is_deleted',
      ],
      anon: null,
    },
    write: {
      parent: [
        'id', 'child_id', 'family_id', 'homework_id', 'date', 'subject',
        'start_at', 'end_at', 'seconds', 'created_at', 'updated_at', 'is_deleted',
      ],
      child: [
        'id', 'child_id', 'family_id', 'homework_id', 'date', 'subject',
        'start_at', 'end_at', 'seconds', 'created_at', 'updated_at', 'is_deleted',
      ],
    },
  },

  app_releases: {
    name: 'app_releases',
    scope: 'global',
    columns: [
      col('id', 'text'),
      col('platform', 'text'),
      col('version_name', 'text'),
      col('version_code', 'int'),
      col('download_url', 'text'),
      col('changelog', 'text'),
      col('force_update', 'bool'),
      col('is_active', 'bool'),
      col('published_at', 'text'),
    ],
    read: {
      parent: [
        'id', 'platform', 'version_name', 'version_code', 'download_url',
        'changelog', 'force_update', 'is_active', 'published_at',
      ],
      child: [
        'id', 'platform', 'version_name', 'version_code', 'download_url',
        'changelog', 'force_update', 'is_active', 'published_at',
      ],
      // 版本清单是公开信息：客户端在登录之前就要检查更新。
      anon: [
        'id', 'platform', 'version_name', 'version_code', 'download_url',
        'changelog', 'force_update', 'is_active', 'published_at',
      ],
    },
    write: { parent: null, child: null },
    anonWhere: { column: 'is_active', value: true },
  },
}

export function tableDef(name: string): TableDef | undefined {
  // 只认自有属性，避免 `toString`/`__proto__` 这类原型链键被当成表名
  return Object.prototype.hasOwnProperty.call(TABLES, name)
    ? TABLES[name]
    : undefined
}

export function columnDef(table: TableDef, name: string): ColumnDef | undefined {
  return table.columns.find((c) => c.name === name)
}

/** 把 URL 里的字符串值按列类型转换。转换失败返回 undefined，由调用方报 400。 */
export function coerce(value: string, type: ColType): unknown {
  switch (type) {
    case 'text':
      return value
    case 'bigint':
    case 'int': {
      const n = Number(value)
      return Number.isFinite(n) ? Math.trunc(n) : undefined
    }
    case 'bool':
      if (value === 'true') return true
      if (value === 'false') return false
      return undefined
    case 'jsonb':
      try {
        return JSON.parse(value) as unknown
      } catch {
        return undefined
      }
  }
}
