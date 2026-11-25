/**
 * 统一的业务错误。
 *
 * 客户端（Flutter 的 CloudException / Web 的 ApiError）都会读响应体里的
 * `message` 字段原样展示给用户，所以 message 必须是人话，不是技术术语。
 */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly detail?: string,
  ) {
    super(message)
    this.name = 'HttpError'
  }
}

export const badRequest = (msg = '请求参数不对', detail?: string) =>
  new HttpError(400, msg, detail)

export const unauthorized = (msg = '登录已过期，请重新登录') =>
  new HttpError(401, msg)

export const forbidden = (msg = '没有权限做这个操作') => new HttpError(403, msg)

export const notFound = (msg = '找不到这条记录') => new HttpError(404, msg)

export const conflict = (msg = '记录已存在') => new HttpError(409, msg)

export const tooLarge = (msg = '文件太大了') => new HttpError(413, msg)

export const tooMany = (msg = '尝试太频繁，请稍后再试') => new HttpError(429, msg)

export const notImplemented = (msg = '服务端未启用这个能力') => new HttpError(501, msg)
