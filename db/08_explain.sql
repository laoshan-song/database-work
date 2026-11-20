-- =============================================================================
--  08_explain.sql  —— 索引与执行计划验证
--
--  用法：
--    python scripts/gen_bench.py        -- 建 srdp_bench 并灌入规模数据
--    psql -d srdp_bench -f db/08_explain.sql
--
--  说明：
--    * 演示库只有 3 篇论文，优化器对小表几乎必然选择 Seq Scan，无法体现索引价值；
--      因此本脚本针对规模库 srdp_bench（3000 论文 / 2.4 万材料版本 / 23 万审计日志）。
--    * 每个用例先给出命中索引的默认计划，再用 enable_indexscan/enable_bitmapscan=off
--      模拟“无索引”计划，对比代价（cost）与执行时间（Execution Time）。
--    * 关注点：Index Scan / Index Only Scan / Bitmap Heap Scan 是否出现，
--      以及 rows、Buffers、Execution Time 的差异。
-- =============================================================================
SET search_path TO srdp, public;
\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '=== 0. 数据规模与索引清单 ==================================================='
SELECT (SELECT count(*) FROM paper)            AS papers,
       (SELECT count(*) FROM material_version) AS material_versions,
       (SELECT count(*) FROM submission_batch) AS batches,
       (SELECT count(*) FROM experiment_result) AS results,
       (SELECT count(*) FROM audit_log)        AS audit_logs;

SELECT indexname, tablename
  FROM pg_indexes
 WHERE schemaname = 'srdp'
   AND indexname IN (
       'ix_paper_institute_created', 'ix_confirmation_current_batch',
       'ix_confirmation_current_person', 'ix_audit_object',
       'ix_material_version_latest',
       'ix_run_task_started', 'ix_result_run', 'ix_access_grant_active')
 ORDER BY tablename, indexname;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E1. 论文列表：按研究所过滤 + 创建时间倒序 + LIMIT ======================'
\echo '--- 默认（应命中 ix_paper_institute_created）'
EXPLAIN (ANALYZE, BUFFERS, COSTS ON)
SELECT paper_id, title, visibility_level, created_at
  FROM paper
 WHERE institute_id = 1
 ORDER BY created_at DESC
 LIMIT 20;

\echo '--- 关闭索引扫描（模拟无索引）'
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT paper_id, title, visibility_level, created_at
  FROM paper
 WHERE institute_id = 1
 ORDER BY created_at DESC
 LIMIT 20;
RESET enable_indexscan;
RESET enable_bitmapscan;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E2. 作者待办：部分索引 ix_confirmation_current_batch ==================='
\echo '--- 默认'
EXPLAIN (ANALYZE, BUFFERS)
SELECT batch_id, title, round_no, batch_status, current_state
  FROM v_author_todo
 WHERE person_id = (SELECT person_id FROM person WHERE employee_no = 'B00001');

\echo '--- 关闭索引扫描'
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT batch_id, title, round_no, batch_status, current_state
  FROM v_author_todo
 WHERE person_id = (SELECT person_id FROM person WHERE employee_no = 'B00001');
RESET enable_indexscan;
RESET enable_bitmapscan;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E3. 审计日志：对象类型 + 对象 ID，按时间倒序取最近 20 条 =============='
\echo '--- 默认（应命中 ix_audit_object）'
EXPLAIN (ANALYZE, BUFFERS)
SELECT audit_id, actor_person_id, action, created_at
  FROM audit_log
 WHERE object_type = 'submission_batch'
   AND object_id = '45'
 ORDER BY created_at DESC
 LIMIT 20;

\echo '--- 关闭索引扫描'
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT audit_id, actor_person_id, action, created_at
  FROM audit_log
 WHERE object_type = 'submission_batch'
   AND object_id = '45'
 ORDER BY created_at DESC
 LIMIT 20;
RESET enable_indexscan;
RESET enable_bitmapscan;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E4. 材料最新版本：LATERAL 取每个材料 version_no 最大者 ================'
\echo '--- 默认（应命中 ix_material_version_latest）'
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.material_id, m.name, mv.version_no, mv.created_at
  FROM material m
  JOIN LATERAL (
        SELECT x.version_no, x.created_at
          FROM material_version x
         WHERE x.material_id = m.material_id
         ORDER BY x.version_no DESC
         LIMIT 1
       ) mv ON true
 WHERE m.paper_id = 1500
 ORDER BY m.material_type;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E5. 实验追溯：按图表编号查结果链路（视图 v_result_trace） ============='
\echo '--- 默认'
EXPLAIN (ANALYZE, BUFFERS)
SELECT result_id, run_id, code_version_no, data_version_no
  FROM v_result_trace
 WHERE paper_figure_no = '图3'
 LIMIT 20;

\echo '--- 关闭索引扫描'
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT result_id, run_id, code_version_no, data_version_no
  FROM v_result_trace
 WHERE paper_figure_no = '图3'
 LIMIT 20;
RESET enable_indexscan;
RESET enable_bitmapscan;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E6. 授权校验：fn_access_mode 的索引访问路径 ==========================='
EXPLAIN (ANALYZE, BUFFERS)
SELECT fn_access_mode(
           (SELECT account_id FROM account WHERE username = 'sunhao'),
           (SELECT min(material_version_id) FROM material_version)
       ) AS mode;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== E7. 索引使用统计（需先运行过上面的查询） =============================='
-- 统计收集是异步的，强制刷新一次再读取
SELECT pg_stat_force_next_flush();
SELECT pg_sleep(0.2);
SELECT relname AS table_name,
       indexrelname AS index_name,
       idx_scan AS scans,
       idx_tup_read AS tuples_read,
       idx_tup_fetch AS tuples_fetched
  FROM pg_stat_user_indexes
 WHERE schemaname = 'srdp'
   AND indexrelname IN (
       'ix_paper_institute_created', 'ix_confirmation_current_batch',
       'ix_confirmation_current_person', 'ix_audit_object',
       'ix_material_version_latest',
       'ix_run_task_started', 'ix_result_run', 'ix_access_grant_active')
 ORDER BY idx_scan DESC, index_name;
