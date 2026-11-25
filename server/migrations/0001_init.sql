-- 家庭作业系统 · 初始 schema
--
-- 从 CloudBase 的 PG 模式迁到自托管。刻意与旧库保持字段级一致：
-- 客户端 mapper（Flutter 的 models.dart / Web 的 api.ts）对字段名和类型有强假设。
--
-- 与旧库的三处本质差异：
--   1. 没有 anon 角色、没有 RLS —— 隔离改在应用层用 family_id 强制注入
--   2. 没有外键 —— 孩子被软删后作业仍要在，不能级联
--   3. 主键全部由客户端提供 UUID，服务端不生成、不自增

CREATE TABLE IF NOT EXISTS families (
  id         TEXT PRIMARY KEY,
  code       TEXT NOT NULL UNIQUE,
  name       TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS children (
  id          TEXT PRIMARY KEY,
  family_id   TEXT NOT NULL,
  name        TEXT NOT NULL,
  color_index INTEGER NOT NULL DEFAULT 0,
  created_at  BIGINT NOT NULL,
  updated_at  BIGINT NOT NULL,
  is_deleted  BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_children_family ON children (family_id);

CREATE TABLE IF NOT EXISTS homework (
  id         TEXT PRIMARY KEY,
  child_id   TEXT NOT NULL,
  family_id  TEXT NOT NULL DEFAULT '',
  date       TEXT NOT NULL,
  subject    TEXT NOT NULL,
  content    TEXT NOT NULL DEFAULT '',
  -- 必须是 JSONB 数组，且必须保留空串槽位：
  -- 正文里的 [图N] 按下标定位图片，过滤掉空串会让后续所有图错位。
  images     JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_done    BOOLEAN NOT NULL DEFAULT FALSE,
  done_at    BIGINT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_homework_family_date ON homework (family_id, date);
CREATE INDEX IF NOT EXISTS idx_homework_child_date ON homework (child_id, date);

CREATE TABLE IF NOT EXISTS homework_sessions (
  id          TEXT PRIMARY KEY,
  child_id    TEXT,
  family_id   TEXT NOT NULL DEFAULT '',
  homework_id TEXT,
  date        TEXT,
  subject     TEXT,
  start_at    BIGINT,
  end_at      BIGINT,
  seconds     INTEGER,
  created_at  BIGINT NOT NULL,
  updated_at  BIGINT NOT NULL,
  is_deleted  BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_sessions_family_date ON homework_sessions (family_id, date);
CREATE INDEX IF NOT EXISTS idx_sessions_child_date ON homework_sessions (child_id, date);

CREATE TABLE IF NOT EXISTS app_releases (
  id           TEXT PRIMARY KEY,
  platform     TEXT NOT NULL,
  version_name TEXT NOT NULL,
  version_code INTEGER NOT NULL,
  download_url TEXT NOT NULL,
  changelog    TEXT NOT NULL DEFAULT '',
  force_update BOOLEAN NOT NULL DEFAULT FALSE,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (platform, version_code)
);

-- refresh 会话。存 hash 不存明文：库被读走也不能直接换 token。
CREATE TABLE IF NOT EXISTS sessions (
  id           TEXT PRIMARY KEY,
  family_id    TEXT NOT NULL,
  role         TEXT NOT NULL CHECK (role IN ('parent', 'child')),
  child_id     TEXT,
  refresh_hash TEXT NOT NULL UNIQUE,
  device_id    TEXT,
  created_at   BIGINT NOT NULL,
  last_used_at BIGINT,
  expires_at   BIGINT NOT NULL,
  revoked_at   BIGINT
);
CREATE INDEX IF NOT EXISTS idx_sessions_family ON sessions (family_id);
CREATE INDEX IF NOT EXISTS idx_sessions_child ON sessions (child_id);
