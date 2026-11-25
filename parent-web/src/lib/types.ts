/** 与云端表字段一一对应的领域模型。字段命名沿用后端 snake_case 的语义，
 *  但内部一律用 camelCase，转换集中在 cloud.ts 的 mapper 里。 */

export interface Family {
  id: string
  /** 6 位家庭码，家长端的唯一凭证 */
  code: string
  name: string
  createdAt: number
}

export interface Child {
  id: string
  familyId: string
  name: string
  /** 头像配色下标，对应 CHILD_COLORS */
  colorIndex: number
  createdAt: number
}

/**
 * 作业里除正文和图片之外的块级内容。
 *
 * 两种形态共用一条记录：
 *   - `file`：PDF / DOCX，正文挂在云存储 key 上，云端只存元数据；
 *   - `link`：网页链接，存标题 / 描述 / 站点 / 缩略图，点开交给浏览器。
 *
 * 字段名与手机端 `Attachment.toCloudMap()` 完全一致 —— 数据库里就是这一坨 JSON，
 * 两端谁写谁读，字段对不上就会出现「手机发的附件网页上看不见」。
 */
export interface Attachment {
  /** 稳定 id：云端对象 key 用它拼，删中间一个也不会互相覆盖 */
  id: string
  kind: 'file' | 'link'
  /** 仅 file：云存储 key，空串表示还没传上去 */
  key: string
  /** 文件名（含扩展名） */
  name: string
  /** 字节数，用来显示「2.6 MB」 */
  size: number
  mime: string
  /** 以下五个仅 link */
  url: string
  title: string
  desc: string
  site: string
  image: string
}

export interface Homework {
  id: string
  childId: string
  familyId: string
  /** yyyy-MM-dd，作业所属日期（不是创建日期） */
  date: string
  subject: string
  /** 纯文本正文，图片位置用行内标记 [图N] 表示 */
  content: string
  /** 云存储 key，下标 + 1 对应正文里的 [图N] */
  imageKeys: string[]
  /** 附件与链接，统一排在图片之后，不参与正文内联排版 */
  attachments: Attachment[]
  isDone: boolean
  doneAt: number | null
  createdAt: number
  updatedAt: number
  isDeleted: boolean
}

/** 新建/编辑作业时提交给云端的字段集合。
 *  刻意只带内容字段：孩子端的 is_done / done_at 由孩子端写，
 *  两端字段不重叠，家长保存不会冲掉孩子打的勾。 */
export interface HomeworkDraft {
  childId: string
  familyId: string
  date: string
  subject: string
  content: string
  imageKeys: string[]
  attachments: Attachment[]
}
