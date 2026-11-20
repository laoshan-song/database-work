-- =============================================================================
--  02_views.sql  —— 视图
--  依赖：01_schema.sql
-- =============================================================================
SET search_path TO srdp, public;

-- -----------------------------------------------------------------------------
-- 批次进度：确认人数 / 作者总数 / 异议 / 最近更新时间
-- 只统计 is_current 的确认记录，历史记录不参与进度
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_batch_progress AS
SELECT b.batch_id,
       b.paper_id,
       b.round_no,
       b.institute_id,
       b.initiated_by,
       b.status,
       b.author_count,
       COALESCE(c.confirmed_count, 0) AS confirmed_count,
       COALESCE(c.disputed_count, 0)  AS disputed_count,
       COALESCE(c.withdrawn_count, 0) AS withdrawn_count,
       b.created_at,
       b.frozen_at,
       b.submitted_at,
       b.ended_at,
       b.ended_reason,
       GREATEST(b.created_at,
                COALESCE(b.submitted_at, b.created_at),
                COALESCE(b.ended_at, b.created_at),
                COALESCE(c.last_action_at, b.created_at)) AS last_updated_at
FROM submission_batch b
LEFT JOIN (
    SELECT batch_id,
           count(*) FILTER (WHERE action = 'CONFIRM')  AS confirmed_count,
           count(*) FILTER (WHERE action = 'DISPUTE')  AS disputed_count,
           count(*) FILTER (WHERE action = 'WITHDRAW') AS withdrawn_count,
           max(created_at)                             AS last_action_at
    FROM confirmation
    WHERE is_current
    GROUP BY batch_id
) c ON c.batch_id = b.batch_id;

COMMENT ON VIEW v_batch_progress IS '批次进度视图：作者总数、已确认/异议/撤回人数及最近更新时间';

-- -----------------------------------------------------------------------------
-- 汇交总览（任务书要求）：每篇论文的当前批次、确认人数、作者总数、审核状态、最近更新
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_submission_overview AS
SELECT p.paper_id,
       p.title,
       p.institute_id,
       i.name  AS institute_name,
       p.owner_person_id,
       op.name AS owner_name,
       p.submission_status,
       p.visibility_level,
       b.batch_id        AS current_batch_id,
       b.round_no        AS current_round,
       b.status          AS batch_status,
       b.author_count,
       b.confirmed_count,
       b.disputed_count,
       b.last_updated_at
FROM paper p
JOIN institute i ON i.institute_id = p.institute_id
JOIN person op   ON op.person_id = p.owner_person_id
LEFT JOIN LATERAL (
    SELECT v.batch_id, v.round_no, v.status, v.author_count,
           v.confirmed_count, v.disputed_count, v.last_updated_at
    FROM v_batch_progress v
    WHERE v.paper_id = p.paper_id
    ORDER BY v.round_no DESC
    LIMIT 1
) b ON true;

COMMENT ON VIEW v_submission_overview IS '汇交总览：当前批次、确认进度、审核状态、最近更新时间';

-- -----------------------------------------------------------------------------
-- 作者确认明细：批次名单 + 当前有效确认状态（历史条数单独给出）
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_confirmation_detail AS
SELECT ba.batch_id,
       b.paper_id,
       p.title,
       b.round_no,
       b.status            AS batch_status,
       ba.person_id,
       per.name            AS person_name,
       per.employee_no,
       ba.author_order,
       ba.is_corresponding,
       ba.is_external,
       ba.is_owner,
       COALESCE(cur.action, 'PENDING') AS current_state,
       cur.created_at      AS acted_at,
       cur.comment,
       (SELECT count(*)
          FROM confirmation h
         WHERE h.batch_id = ba.batch_id
           AND h.person_id = ba.person_id) AS history_count
FROM batch_author ba
JOIN submission_batch b ON b.batch_id = ba.batch_id
JOIN paper p            ON p.paper_id = b.paper_id
JOIN person per         ON per.person_id = ba.person_id
LEFT JOIN confirmation cur
       ON cur.batch_id = ba.batch_id
      AND cur.person_id = ba.person_id
      AND cur.is_current;

COMMENT ON VIEW v_confirmation_detail IS '作者确认明细：本批次名单与当前有效状态';

-- -----------------------------------------------------------------------------
-- 作者待办：处于确认阶段且本人尚未有效确认的名单
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_author_todo AS
SELECT b.batch_id,
       b.paper_id,
       p.title,
       b.round_no,
       b.institute_id,
       ba.person_id,
       ba.name_snapshot AS person_name,
       ba.author_order,
       b.status         AS batch_status,
       COALESCE(cur.action, 'PENDING') AS current_state,
       cur.created_at   AS acted_at,
       b.frozen_at
FROM submission_batch b
JOIN paper p        ON p.paper_id = b.paper_id
JOIN batch_author ba ON ba.batch_id = b.batch_id
LEFT JOIN confirmation cur
       ON cur.batch_id = ba.batch_id
      AND cur.person_id = ba.person_id
      AND cur.is_current
WHERE b.status IN ('PENDING_AUTHORS', 'READY_TO_SUBMIT')
  AND COALESCE(cur.action, 'PENDING') <> 'CONFIRM';

COMMENT ON VIEW v_author_todo IS '作者待办：待确认/已撤回的批次作者';

-- -----------------------------------------------------------------------------
-- 研究所未完成确认论文：按所统计尚未全员确认或仍在审核中的论文
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_unfinished_papers AS
SELECT i.institute_id,
       i.name AS institute_name,
       p.paper_id,
       p.title,
       p.owner_person_id,
       op.name AS owner_name,
       v.current_batch_id,
       v.current_round,
       v.batch_status,
       v.author_count,
       v.confirmed_count,
       (v.author_count - v.confirmed_count) AS missing_count,
       v.last_updated_at
FROM paper p
JOIN institute i ON i.institute_id = p.institute_id
JOIN person op   ON op.person_id = p.owner_person_id
JOIN v_submission_overview v ON v.paper_id = p.paper_id
WHERE v.batch_status IN ('PENDING_AUTHORS', 'READY_TO_SUBMIT', 'PENDING_ADMIN', 'UNDER_REVIEW')
  AND v.confirmed_count < v.author_count;

COMMENT ON VIEW v_unfinished_papers IS '研究所未完成确认论文清单';

-- -----------------------------------------------------------------------------
-- 实验结果反向追溯：结果 → 运行 → 实际使用的代码/数据/配置/日志版本
-- 注意：展示的是运行登记时引用的版本，不是材料的最新版本
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_result_trace AS
SELECT r.result_id,
       t.task_id,
       t.title  AS task_title,
       p.paper_id,
       p.title  AS paper_title,
       run.run_id,
       run.run_label,
       run.started_at,
       run.ended_at,
       run.status     AS run_status,
       run.parameters,
       run.hardware_env,
       run.software_env,
       run.code_version_id,
       m_code.name    AS code_name,
       mv_code.version_no AS code_version_no,
       mv_code.sha256 AS code_sha256,
       run.data_version_id,
       m_data.name    AS data_name,
       mv_data.version_no AS data_version_no,
       mv_data.sha256 AS data_sha256,
       run.config_version_id,
       m_cfg.name     AS config_name,
       mv_cfg.version_no AS config_version_no,
       run.log_version_id,
       m_log.name     AS log_name,
       mv_log.version_no AS log_version_no,
       r.result_version_id,
       m_res.name     AS result_name,
       mv_res.version_no AS result_version_no,
       r.metric_summary,
       r.paper_figure_no,
       r.conclusion
FROM experiment_result r
JOIN experiment_run  run    ON run.run_id = r.run_id
JOIN experiment_task t      ON t.task_id = run.task_id
JOIN paper p                ON p.paper_id = t.paper_id
JOIN material_version mv_code ON mv_code.material_version_id = run.code_version_id
JOIN material m_code          ON m_code.material_id = mv_code.material_id
JOIN material_version mv_data ON mv_data.material_version_id = run.data_version_id
JOIN material m_data          ON m_data.material_id = mv_data.material_id
LEFT JOIN material_version mv_cfg ON mv_cfg.material_version_id = run.config_version_id
LEFT JOIN material m_cfg          ON m_cfg.material_id = mv_cfg.material_id
LEFT JOIN material_version mv_log ON mv_log.material_version_id = run.log_version_id
LEFT JOIN material m_log          ON m_log.material_id = mv_log.material_id
JOIN material_version mv_res  ON mv_res.material_version_id = r.result_version_id
JOIN material m_res           ON m_res.material_id = mv_res.material_id;

COMMENT ON VIEW v_result_trace IS '实验结果反向追溯：结果到运行到实际使用版本';

-- -----------------------------------------------------------------------------
-- 材料版本总览（含最新版本标记），供材料页与访问申请使用
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_material_version AS
SELECT mv.material_version_id,
       mv.material_id,
       m.paper_id,
       m.material_type,
       m.name,
       mv.version_no,
       mv.sha256,
       mv.change_note,
       mv.created_by,
       mv.created_at,
       f.file_id,
       f.original_name,
       f.file_format,
       f.size_bytes,
       (mv.version_no = (SELECT max(x.version_no) FROM material_version x WHERE x.material_id = m.material_id)) AS is_latest
FROM material_version mv
JOIN material m      ON m.material_id = mv.material_id
JOIN file_object f   ON f.file_id = mv.file_id;

COMMENT ON VIEW v_material_version IS '材料版本总览，is_latest 标记最新版（仅展示用，历史引用不受影响）';

-- -----------------------------------------------------------------------------
-- 访问授权有效状态
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_access_grant_status AS
SELECT g.grant_id,
       g.account_id,
       g.material_version_id,
       g.scope,
       g.valid_from,
       g.valid_to,
       g.revoked_at,
       g.download_count,
       g.max_downloads,
       CASE
           WHEN g.revoked_at IS NOT NULL THEN 'REVOKED'
           WHEN now() < g.valid_from THEN 'NOT_YET'
           WHEN now() > g.valid_to THEN 'EXPIRED'
           WHEN g.max_downloads IS NOT NULL AND g.download_count >= g.max_downloads THEN 'EXHAUSTED'
           ELSE 'ACTIVE'
       END AS grant_status,
       r.request_id,
       r.reason,
       r.decided_by,
       r.decided_at
FROM access_grant g
JOIN access_request r ON r.request_id = g.request_id;

COMMENT ON VIEW v_access_grant_status IS '授权状态：生效/未生效/过期/撤销/次数用尽';
