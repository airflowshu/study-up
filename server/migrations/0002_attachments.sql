-- 作业附件：PDF / DOCX 文件与链接卡片。
--
-- 单独一列而不是塞进 images：
--   - images 是"按槽位对齐正文 [图N] 的图片数组"，附件不参与内联排版；
--   - 两者的字段形状也不同，混在一起会让 REST 的列校验和客户端解析都变复杂。
--
-- 形状：[{kind:'file', name, size, mime, key} | {kind:'link', url, title, desc, site, image}]
-- 老数据一律是空数组，客户端无需特判。
ALTER TABLE homework
  ADD COLUMN IF NOT EXISTS attachments JSONB NOT NULL DEFAULT '[]'::jsonb;
