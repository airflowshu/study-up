CREATE TABLE IF NOT EXISTS families (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS children (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  name TEXT NOT NULL,
  color_index INTEGER NOT NULL DEFAULT 0,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS homework (
  id TEXT PRIMARY KEY,
  child_id TEXT NOT NULL,
  family_id TEXT NOT NULL DEFAULT '',
  date TEXT NOT NULL,
  subject TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  images JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_done BOOLEAN NOT NULL DEFAULT FALSE,
  done_at BIGINT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_homework_child_date ON homework(child_id, date);
CREATE INDEX IF NOT EXISTS idx_children_family ON children(family_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON families, children, homework TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON families, children, homework TO authenticated;

ALTER TABLE families ENABLE ROW LEVEL SECURITY;
ALTER TABLE children ENABLE ROW LEVEL SECURITY;
ALTER TABLE homework ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_all_families ON families FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY auth_all_families ON families FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY anon_all_children ON children FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY auth_all_children ON children FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY anon_all_homework ON homework FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY auth_all_homework ON homework FOR ALL TO authenticated USING (true) WITH CHECK (true);
