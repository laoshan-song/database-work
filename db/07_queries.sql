-- =============================================================================
--  07_queries.sql  —— 课程要求的代表性查询
--  用法：psql -d srdp -v batch_id=2 -v paper_id=2 -v person_id=11 -f 07_queries.sql
--        未传变量时使用默认值（下方 \if 判断）
--  说明：应用层使用参数化 SQL 重写这些查询，本文件用于报告与验收演示。
-- =============================================================================
SET search_path TO srdp, public;
\set ON_ERROR_STOP on

\if :{?batch_id}
\else
  \set batch_id 2
\endif
\if :{?paper_id}
\else
  \set paper_id 2
\endif
\if :{?person_id}
\else
  \set person_id 11
\endif

-- -----------------------------------------------------------------------------
-- Q1 作者确认明细（关联 + 聚合 + 存在性判断）
--    展示本批次作者顺序、当前状态、历史操作次数与最近意见
-- -----------------------------------------------------------------------------
SELECT ba.author_order                                   AS 顺序,
       per.name                                          AS 作者,
       CASE WHEN ba.is_external THEN '外部' ELSE '内部' END AS 单位类型,
       ba.affiliation_snapshot                           AS 单位,
       COALESCE(c.action, 'PENDING')                     AS 当前状态,
       c.created_at                                      AS 操作时间,
       c.comment                                         AS 意见,
       (SELECT count(*) FROM confirmation h
         WHERE h.batch_id = ba.batch_id AND h.person_id = ba.person_id) AS 历史操作次数
FROM batch_author ba
JOIN person per ON per.person_id = ba.person_id
LEFT JOIN confirmation c
       ON c.batch_id = ba.batch_id
      AND c.person_id = ba.person_id
      AND c.is_current
WHERE ba.batch_id = :batch_id
ORDER BY ba.author_order;

-- -----------------------------------------------------------------------------
-- Q2 研究所未完成确认论文（聚合 + HAVING + 字符串聚合）
--    列出每个所未全员确认的论文、缺口人数与未确认人员姓名
-- -----------------------------------------------------------------------------
SELECT i.name                                             AS 研究所,
       p.title                                            AS 论文,
       b.round_no                                         AS 轮次,
       b.status                                           AS 批次状态,
       count(*)                                           AS 作者总数,
       count(*) FILTER (WHERE c.action = 'CONFIRM')       AS 已确认,
       count(*) FILTER (WHERE COALESCE(c.action,'PENDING') <> 'CONFIRM') AS 未确认人数,
       string_agg(per.name, '、' ORDER BY ba.author_order)
           FILTER (WHERE COALESCE(c.action,'PENDING') <> 'CONFIRM')      AS 未确认人员
FROM institute i
JOIN paper p              ON p.institute_id = i.institute_id
JOIN submission_batch b   ON b.paper_id = p.paper_id
JOIN batch_author ba      ON ba.batch_id = b.batch_id
JOIN person per           ON per.person_id = ba.person_id
LEFT JOIN confirmation c  ON c.batch_id = ba.batch_id
                         AND c.person_id = ba.person_id
                         AND c.is_current
WHERE b.status IN ('PENDING_AUTHORS','READY_TO_SUBMIT','PENDING_ADMIN','UNDER_REVIEW')
GROUP BY i.name, p.title, b.round_no, b.status, b.batch_id
HAVING count(*) FILTER (WHERE c.action = 'CONFIRM') < count(*)
ORDER BY i.name, p.title;

-- -----------------------------------------------------------------------------
-- Q3 实验结果反向追溯：结果文件 -> 运行 -> 实际使用的代码/数据/配置/日志版本
--    核心点：引用的是运行登记时的版本，不是材料最新版
-- -----------------------------------------------------------------------------
SELECT r.paper_figure_no   AS 图表编号,
       m_res.name          AS 结果材料,
       mv_res.version_no   AS 结果版本,
       run.run_label       AS 运行批次,
       m_code.name         AS 代码材料,
       mv_code.version_no  AS 代码版本,
       m_data.name         AS 数据材料,
       mv_data.version_no  AS 数据版本,
       m_cfg.name          AS 配置材料,
       mv_cfg.version_no   AS 配置版本,
       m_log.name          AS 日志材料,
       mv_log.version_no   AS 日志版本,
       run.parameters      AS 参数,
       run.software_env    AS 软件环境,
       r.metric_summary    AS 指标,
       r.conclusion        AS 结论
FROM experiment_result r
JOIN experiment_run  run     ON run.run_id = r.run_id
JOIN experiment_task t       ON t.task_id = run.task_id
JOIN material_version mv_code ON mv_code.material_version_id = run.code_version_id
JOIN material m_code          ON m_code.material_id = mv_code.material_id
JOIN material_version mv_data ON mv_data.material_version_id = run.data_version_id
JOIN material m_data          ON m_data.material_id = mv_data.material_id
LEFT JOIN material_version mv_cfg ON mv_cfg.material_version_id = run.config_version_id
LEFT JOIN material m_cfg          ON m_cfg.material_id = mv_cfg.material_id
LEFT JOIN material_version mv_log ON mv_log.material_version_id = run.log_version_id
LEFT JOIN material m_log          ON m_log.material_id = mv_log.material_id
JOIN material_version mv_res  ON mv_res.material_version_id = r.result_version_id
JOIN material m_res           ON m_res.material_id = mv_res.material_id
WHERE t.paper_id = :paper_id
ORDER BY run.started_at;

-- -----------------------------------------------------------------------------
-- Q4 批次材料清单与版本（确认送审内容）
-- -----------------------------------------------------------------------------
SELECT bm.material_type                                   AS 材料类型,
       bm.material_name_snapshot                          AS 材料名称,
       bm.version_no_snapshot                             AS 版本号,
       left(bm.sha256_snapshot, 12) || '…'                AS SHA256前缀,
       (SELECT count(*) FROM material_version x
         WHERE x.material_id = mv.material_id)            AS 材料总版本数,
       (SELECT x.version_no FROM material_version x
         WHERE x.material_id = mv.material_id
         ORDER BY x.version_no DESC LIMIT 1)              AS 当前最新版本
FROM batch_material bm
JOIN material_version mv ON mv.material_version_id = bm.material_version_id
WHERE bm.batch_id = :batch_id
ORDER BY bm.material_type, bm.material_name_snapshot;

-- -----------------------------------------------------------------------------
-- Q5 我的待办：本人尚未确认的批次
-- -----------------------------------------------------------------------------
SELECT t.batch_id                                         AS 批次,
       t.title                                            AS 论文,
       t.round_no                                         AS 轮次,
       t.batch_status                                     AS 批次状态,
       t.current_state                                    AS 我的状态,
       t.frozen_at                                        AS 冻结时间,
       (SELECT count(*) FROM batch_author ba
         WHERE ba.batch_id = t.batch_id)                  AS 作者总数,
       (SELECT count(*) FROM confirmation c
         WHERE c.batch_id = t.batch_id AND c.is_current AND c.action = 'CONFIRM') AS 已确认
FROM v_author_todo t
WHERE t.person_id = :person_id
ORDER BY t.frozen_at;

-- -----------------------------------------------------------------------------
-- Q6 访问申请与授权状态（区分"申请状态"与"实际授权"）
-- -----------------------------------------------------------------------------
SELECT ar.request_id                                      AS 申请号,
       per.name                                           AS 申请人,
       p.title                                            AS 论文,
       m.name                                             AS 材料,
       mv.version_no                                      AS 版本,
       ar.status                                          AS 申请状态,
       ar.created_at                                      AS 申请时间,
       ar.decided_at                                      AS 审批时间,
       gs.grant_status                                    AS 授权状态,
       gs.valid_to                                        AS 有效期至,
       gs.download_count || ' / ' || COALESCE(gs.max_downloads::text, '不限') AS 已下载次数
FROM access_request ar
JOIN account a     ON a.account_id = ar.requester_account_id
JOIN person per    ON per.person_id = a.person_id
JOIN material_version mv ON mv.material_version_id = ar.material_version_id
JOIN material m    ON m.material_id = mv.material_id
JOIN paper p       ON p.paper_id = m.paper_id
LEFT JOIN v_access_grant_status gs ON gs.request_id = ar.request_id
ORDER BY ar.created_at DESC;

-- -----------------------------------------------------------------------------
-- Q7 下载统计（按材料版本聚合）
-- -----------------------------------------------------------------------------
SELECT p.title                                            AS 论文,
       m.name                                             AS 材料,
       mv.version_no                                      AS 版本,
       count(*) FILTER (WHERE al.action = 'DOWNLOAD')     AS 下载次数,
       count(DISTINCT al.account_id)                      AS 下载人数,
       max(al.created_at)                                 AS 最近下载
FROM access_log al
JOIN material_version mv ON mv.material_version_id = al.material_version_id
JOIN material m          ON m.material_id = mv.material_id
JOIN paper p             ON p.paper_id = m.paper_id
GROUP BY p.title, m.name, mv.version_no
HAVING count(*) FILTER (WHERE al.action = 'DOWNLOAD') > 0
ORDER BY 下载次数 DESC;

-- -----------------------------------------------------------------------------
-- Q8 两轮批次差异：作者、材料、实验运行的变化（用于复核"补充后新批次"）
--    参数：batch_a / batch_b 可用 :batch_id 与另一批次替换
-- -----------------------------------------------------------------------------
WITH a AS (SELECT :batch_id::bigint AS bid),
     b AS (SELECT max(batch_id) AS bid FROM submission_batch WHERE paper_id = :paper_id)
SELECT '作者' AS 类别,
       COALESCE(x.name, y.name) AS 对象,
       CASE WHEN x.person_id IS NULL THEN '新增'
            WHEN y.person_id IS NULL THEN '移除'
            ELSE '保留' END AS 变化
FROM (SELECT ba.person_id, per.name FROM batch_author ba
       JOIN person per ON per.person_id = ba.person_id
      WHERE ba.batch_id = (SELECT bid FROM a)) x
FULL JOIN (SELECT ba.person_id, per.name FROM batch_author ba
            JOIN person per ON per.person_id = ba.person_id
           WHERE ba.batch_id = (SELECT bid FROM b)) y USING (person_id)
UNION ALL
SELECT '材料',
       COALESCE(x.material_name_snapshot, y.material_name_snapshot),
       CASE WHEN x.material_version_id IS NULL THEN '新增'
            WHEN y.material_version_id IS NULL THEN '移除'
            WHEN x.version_no_snapshot <> y.version_no_snapshot THEN '版本变化'
            ELSE '保留' END
FROM (SELECT * FROM batch_material WHERE batch_id = (SELECT bid FROM a)) x
FULL JOIN (SELECT * FROM batch_material WHERE batch_id = (SELECT bid FROM b)) y
     USING (material_version_id)
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- Q9 权限自检：某账号对某材料版本的访问来源（NULL 表示无权）
-- -----------------------------------------------------------------------------
SELECT a.username,
       m.name,
       mv.version_no,
       fn_access_mode(a.account_id, mv.material_version_id) AS 访问来源
FROM account a
CROSS JOIN material_version mv
JOIN material m ON m.material_id = mv.material_id
WHERE a.username = 'sunhao'
  AND m.paper_id = :paper_id
ORDER BY m.name, mv.version_no;

-- -----------------------------------------------------------------------------
-- Q10 审计轨迹：某批次从发起到归档的全部关键操作
-- -----------------------------------------------------------------------------
SELECT al.created_at,
       COALESCE(per.name, '系统') AS 操作者,
       al.object_type,
       al.action,
       al.summary
FROM audit_log al
LEFT JOIN person per ON per.person_id = al.actor_person_id
WHERE (al.object_type = 'submission_batch' AND al.object_id = :batch_id::text)
   OR (al.object_type IN ('confirmation','admin_review')
       AND ((al.summary->>'batch_id') = :batch_id::text
            OR al.object_id LIKE :batch_id::text || ':%'))
ORDER BY al.created_at;
