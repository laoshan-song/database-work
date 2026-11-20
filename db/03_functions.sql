-- =============================================================================
--  03_functions.sql  —— 业务存储过程 / 函数
--  依赖：01_schema.sql, 02_views.sql
--  约定：所有写业务的过程返回 op_result(ok, code, message)，由应用层转换为提示
--        所有涉及批次状态的过程先对 submission_batch 行加 FOR UPDATE 锁，
--        从而使"提交审核 / 撤回确认 / 撤回批次 / 审核"串行化。
-- =============================================================================
SET search_path TO srdp, public;

DROP TYPE IF EXISTS op_result CASCADE;
CREATE TYPE op_result AS (
    ok      boolean,
    code    varchar(32),
    message text
);

CREATE OR REPLACE FUNCTION fn_audit(
    p_actor      bigint,
    p_object_type text,
    p_object_id   text,
    p_action      text,
    p_summary     jsonb DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary)
    VALUES (p_actor, p_object_type, p_object_id, p_action, p_summary);
$$;

CREATE OR REPLACE FUNCTION fn_is_sys_admin(p_person_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM account a
         WHERE a.person_id = p_person_id
           AND a.is_enabled
           AND a.is_system_admin
    );
$$;

CREATE OR REPLACE FUNCTION fn_is_institute_admin(p_person_id bigint, p_institute_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM account a
          JOIN account_role ar ON ar.account_id = a.account_id
         WHERE a.person_id = p_person_id
           AND a.is_enabled
           AND ar.role_code = 'INSTITUTE_ADMIN'
           AND ar.institute_id = p_institute_id
           AND ar.is_active
    );
$$;

CREATE OR REPLACE FUNCTION fn_is_paper_maintainer(p_person_id bigint, p_paper_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM paper_maintainer pm
         WHERE pm.paper_id = p_paper_id
           AND pm.person_id = p_person_id
           AND pm.revoked_at IS NULL
    );
$$;

-- 能否访问某材料版本：返回访问来源，NULL 表示无权
-- AUTHOR > PUBLIC > INSTITUTE > GRANT:DOWNLOAD / GRANT:VIEW
CREATE OR REPLACE FUNCTION fn_access_mode(p_account_id bigint, p_material_version_id bigint)
RETURNS text LANGUAGE sql STABLE AS $$
WITH ctx AS (
    SELECT m.paper_id,
           p.institute_id,
           p.visibility_level,
           p.owner_person_id,
           EXISTS (SELECT 1 FROM submission_batch b
                    WHERE b.paper_id = p.paper_id AND b.status = 'ARCHIVED') AS archived
      FROM material_version mv
      JOIN material m ON m.material_id = mv.material_id
      JOIN paper p    ON p.paper_id = m.paper_id
     WHERE mv.material_version_id = p_material_version_id
), me AS (
    SELECT a.account_id, a.person_id
      FROM account a
     WHERE a.account_id = p_account_id AND a.is_enabled
)
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM ctx) OR NOT EXISTS (SELECT 1 FROM me) THEN NULL

    WHEN EXISTS (
        SELECT 1 FROM me m, ctx c
         WHERE m.person_id = c.owner_person_id
            OR EXISTS (SELECT 1 FROM paper_author pa
                        WHERE pa.paper_id = c.paper_id AND pa.person_id = m.person_id)
            OR EXISTS (SELECT 1 FROM paper_maintainer pm
                        WHERE pm.paper_id = c.paper_id AND pm.person_id = m.person_id
                          AND pm.revoked_at IS NULL)
    ) THEN 'AUTHOR'

    WHEN (SELECT archived FROM ctx)
     AND (SELECT visibility_level FROM ctx) = 'PUBLIC' THEN 'PUBLIC'

    WHEN (SELECT archived FROM ctx)
     AND (SELECT visibility_level FROM ctx) = 'INSTITUTE'
     AND EXISTS (
         SELECT 1
           FROM me m
           JOIN ctx c ON true
           JOIN person_affiliation af ON af.person_id = m.person_id
          WHERE af.institute_id = c.institute_id
            AND af.valid_from <= CURRENT_DATE
            AND (af.valid_to IS NULL OR af.valid_to >= CURRENT_DATE)
     ) THEN 'INSTITUTE'

    WHEN EXISTS (
        SELECT 1 FROM access_grant g
         WHERE g.account_id = p_account_id
           AND g.material_version_id = p_material_version_id
           AND g.revoked_at IS NULL
           AND now() >= g.valid_from
           AND now() <= g.valid_to
           AND (g.max_downloads IS NULL OR g.download_count < g.max_downloads)
    ) THEN (
        SELECT 'GRANT:' || g.scope
          FROM access_grant g
         WHERE g.account_id = p_account_id
           AND g.material_version_id = p_material_version_id
           AND g.revoked_at IS NULL
           AND now() >= g.valid_from
           AND now() <= g.valid_to
           AND (g.max_downloads IS NULL OR g.download_count < g.max_downloads)
         ORDER BY g.grant_id DESC
         LIMIT 1
    )
    ELSE NULL
END;
$$;

CREATE OR REPLACE FUNCTION fn_can_view_material(p_account_id bigint, p_material_version_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT fn_access_mode(p_account_id, p_material_version_id) IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION fn_can_download_material(p_account_id bigint, p_material_version_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT fn_access_mode(p_account_id, p_material_version_id) IN
           ('AUTHOR','PUBLIC','INSTITUTE','GRANT:DOWNLOAD');
$$;

-- -----------------------------------------------------------------------------
-- 通知 / 邮件（邮件写到 mail_outbox，演示环境由脚本标记为 SENT）
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notify(
    p_person_id bigint,
    p_category  text,
    p_title     text,
    p_body      text,
    p_link      text DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO notification (account_id, category, title, body, link_url)
    SELECT a.account_id, p_category, p_title, p_body, p_link
      FROM account a
     WHERE a.person_id = p_person_id AND a.is_enabled;
$$;

CREATE OR REPLACE FUNCTION fn_queue_mail(
    p_person_id   bigint,
    p_subject     text,
    p_body        text,
    p_related_type text DEFAULT NULL,
    p_related_id  bigint DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO mail_outbox (to_email, subject, body, related_type, related_id)
    SELECT p.email, p_subject, p_body, p_related_type, p_related_id
      FROM person p
     WHERE p.person_id = p_person_id;
$$;

-- -----------------------------------------------------------------------------
-- 批次创建 / 刷新草稿 / 维护材料
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_create_batch(
    p_paper_id         bigint,
    p_actor_person_id  bigint,
    p_paper_version_id bigint DEFAULT NULL
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_paper      paper%ROWTYPE;
    v_round      integer;
    v_batch_id   bigint;
    v_pv         bigint;
    v_authors    integer;
    v_inst_name  text;
BEGIN
    SELECT * INTO v_paper FROM paper WHERE paper_id = p_paper_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN ROW(false, 'NOT_FOUND', '论文不存在')::op_result;
    END IF;

    IF NOT (v_paper.owner_person_id = p_actor_person_id
            OR fn_is_paper_maintainer(p_actor_person_id, p_paper_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '只有负责人或授权维护成员可以创建汇交批次')::op_result;
    END IF;

    IF EXISTS (SELECT 1 FROM submission_batch
                WHERE paper_id = p_paper_id
                  AND status IN ('DRAFT','PENDING_AUTHORS','READY_TO_SUBMIT','PENDING_ADMIN','UNDER_REVIEW')) THEN
        RETURN ROW(false, 'OPEN_BATCH_EXISTS', '该论文已有未结束的批次，请先结束当前批次')::op_result;
    END IF;

    SELECT count(*) INTO v_authors FROM paper_author WHERE paper_id = p_paper_id;
    IF v_authors = 0 THEN
        RETURN ROW(false, 'NO_AUTHOR', '作者名单为空，不能创建批次')::op_result;
    END IF;

    v_pv := COALESCE(
        p_paper_version_id,
        (SELECT pv.paper_version_id FROM paper_version pv
          WHERE pv.paper_id = p_paper_id ORDER BY pv.version_no DESC LIMIT 1));

    SELECT COALESCE(max(round_no), 0) + 1 INTO v_round
      FROM submission_batch WHERE paper_id = p_paper_id;

    SELECT name INTO v_inst_name FROM institute WHERE institute_id = v_paper.institute_id;

    INSERT INTO submission_batch (
        paper_id, round_no, institute_id, initiated_by, status, paper_version_id,
        title_snapshot, abstract_snapshot, keywords_snapshot, research_field_snapshot,
        venue_snapshot, doi_snapshot, visibility_snapshot, owner_snapshot, author_count
    ) VALUES (
        p_paper_id, v_round, v_paper.institute_id, p_actor_person_id, 'DRAFT', v_pv,
        v_paper.title, v_paper.abstract, v_paper.keywords, v_paper.research_field,
        v_paper.venue, v_paper.doi, v_paper.visibility_level, v_paper.owner_person_id, v_authors
    ) RETURNING batch_id INTO v_batch_id;

    INSERT INTO batch_author (batch_id, person_id, author_order, is_corresponding,
                              is_external, is_owner, name_snapshot, affiliation_snapshot)
    SELECT v_batch_id, pa.person_id, pa.author_order, pa.is_corresponding,
           pa.is_external, (pa.person_id = v_paper.owner_person_id),
           per.name, COALESCE(pa.affiliation_text, i.name)
      FROM paper_author pa
      JOIN person per ON per.person_id = pa.person_id
      LEFT JOIN institute i ON i.institute_id = per.home_institute_id
     WHERE pa.paper_id = p_paper_id;

    INSERT INTO batch_material (batch_id, material_version_id, material_type,
                                material_name_snapshot, version_no_snapshot, sha256_snapshot)
    SELECT v_batch_id, mv.material_version_id, m.material_type, m.name, mv.version_no, mv.sha256
      FROM material m
      JOIN LATERAL (SELECT x.* FROM material_version x
                     WHERE x.material_id = m.material_id
                     ORDER BY x.version_no DESC LIMIT 1) mv ON true
     WHERE m.paper_id = p_paper_id;

    INSERT INTO batch_experiment (batch_id, run_id, snapshot)
    SELECT v_batch_id, r.run_id,
           jsonb_build_object(
               'run_label', r.run_label, 'parameters', r.parameters,
               'hardware_env', r.hardware_env, 'software_env', r.software_env,
               'started_at', r.started_at, 'ended_at', r.ended_at, 'status', r.status,
               'code_version_id', r.code_version_id, 'data_version_id', r.data_version_id,
               'config_version_id', r.config_version_id, 'log_version_id', r.log_version_id)
      FROM experiment_run r
      JOIN experiment_task t ON t.task_id = r.task_id
     WHERE t.paper_id = p_paper_id AND r.status = 'SUCCESS';

    PERFORM fn_audit(p_actor_person_id, 'submission_batch', v_batch_id::text, 'CREATE',
                     jsonb_build_object('paper_id', p_paper_id, 'round_no', v_round));

    RETURN ROW(true, 'OK', format('第 %s 轮批次已创建为草稿（%s）', v_round, v_inst_name))::op_result;
END;
$$;

-- 草稿阶段重新抓取当前作者/最新材料/成功运行（发起确认后不可调用）
CREATE OR REPLACE FUNCTION sp_refresh_batch_draft(
    p_batch_id        bigint,
    p_actor_person_id bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b submission_batch%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;
    IF v_b.status <> 'DRAFT' THEN
        RETURN ROW(false, 'BAD_STATE', '只有草稿批次可以刷新内容')::op_result;
    END IF;
    IF NOT (v_b.owner_snapshot = p_actor_person_id
            OR fn_is_paper_maintainer(p_actor_person_id, v_b.paper_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '无权修改该批次')::op_result;
    END IF;

    DELETE FROM batch_author    WHERE batch_id = p_batch_id;
    DELETE FROM batch_material  WHERE batch_id = p_batch_id;
    DELETE FROM batch_experiment WHERE batch_id = p_batch_id;

    INSERT INTO batch_author (batch_id, person_id, author_order, is_corresponding,
                              is_external, is_owner, name_snapshot, affiliation_snapshot)
    SELECT p_batch_id, pa.person_id, pa.author_order, pa.is_corresponding,
           pa.is_external, (pa.person_id = v_b.owner_snapshot),
           per.name, COALESCE(pa.affiliation_text, i.name)
      FROM paper_author pa
      JOIN person per ON per.person_id = pa.person_id
      LEFT JOIN institute i ON i.institute_id = per.home_institute_id
     WHERE pa.paper_id = v_b.paper_id;

    INSERT INTO batch_material (batch_id, material_version_id, material_type,
                                material_name_snapshot, version_no_snapshot, sha256_snapshot)
    SELECT p_batch_id, mv.material_version_id, m.material_type, m.name, mv.version_no, mv.sha256
      FROM material m
      JOIN LATERAL (SELECT x.* FROM material_version x
                     WHERE x.material_id = m.material_id
                     ORDER BY x.version_no DESC LIMIT 1) mv ON true
     WHERE m.paper_id = v_b.paper_id;

    INSERT INTO batch_experiment (batch_id, run_id, snapshot)
    SELECT p_batch_id, r.run_id,
           jsonb_build_object(
               'run_label', r.run_label, 'parameters', r.parameters,
               'hardware_env', r.hardware_env, 'software_env', r.software_env,
               'started_at', r.started_at, 'ended_at', r.ended_at, 'status', r.status,
               'code_version_id', r.code_version_id, 'data_version_id', r.data_version_id,
               'config_version_id', r.config_version_id, 'log_version_id', r.log_version_id)
      FROM experiment_run r
      JOIN experiment_task t ON t.task_id = r.task_id
     WHERE t.paper_id = v_b.paper_id AND r.status = 'SUCCESS';

    UPDATE submission_batch
       SET author_count = (SELECT count(*) FROM batch_author WHERE batch_id = p_batch_id)
     WHERE batch_id = p_batch_id;

    PERFORM fn_audit(p_actor_person_id, 'submission_batch', p_batch_id::text, 'REFRESH_DRAFT', NULL);
    RETURN ROW(true, 'OK', '草稿内容已刷新为当前作者与最新材料版本')::op_result;
END;
$$;

CREATE OR REPLACE FUNCTION sp_set_batch_material(
    p_batch_id             bigint,
    p_material_version_id  bigint,
    p_actor_person_id      bigint,
    p_included             boolean
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b submission_batch%ROWTYPE;
    v_mv record;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;
    IF v_b.status <> 'DRAFT' THEN
        RETURN ROW(false, 'BAD_STATE', '批次已冻结，不能再调整材料')::op_result;
    END IF;
    IF NOT (v_b.owner_snapshot = p_actor_person_id
            OR fn_is_paper_maintainer(p_actor_person_id, v_b.paper_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '无权修改该批次')::op_result;
    END IF;

    SELECT mv.material_version_id, mv.version_no, mv.sha256, m.material_type, m.name, m.paper_id
      INTO v_mv
      FROM material_version mv JOIN material m ON m.material_id = mv.material_id
     WHERE mv.material_version_id = p_material_version_id;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '材料版本不存在')::op_result; END IF;
    IF v_mv.paper_id <> v_b.paper_id THEN
        RETURN ROW(false, 'CROSS_PAPER', '不能引用其他论文的材料')::op_result;
    END IF;

    IF p_included THEN
        INSERT INTO batch_material (batch_id, material_version_id, material_type,
                                    material_name_snapshot, version_no_snapshot, sha256_snapshot)
        VALUES (p_batch_id, p_material_version_id, v_mv.material_type,
                v_mv.name, v_mv.version_no, v_mv.sha256)
        ON CONFLICT (batch_id, material_version_id) DO NOTHING;
    ELSE
        DELETE FROM batch_material
         WHERE batch_id = p_batch_id AND material_version_id = p_material_version_id;
    END IF;
    RETURN ROW(true, 'OK', '材料清单已更新')::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 发起确认：冻结本轮内容，生成作者待办与邮件邀请
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_start_confirmation(
    p_batch_id        bigint,
    p_actor_person_id bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b submission_batch%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;

    IF v_b.status <> 'DRAFT' THEN
        RETURN ROW(false, 'BAD_STATE', '只有草稿批次可以发起确认')::op_result;
    END IF;
    IF NOT (v_b.owner_snapshot = p_actor_person_id
            OR fn_is_paper_maintainer(p_actor_person_id, v_b.paper_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '只有负责人或授权维护成员可以发起确认')::op_result;
    END IF;
    IF v_b.author_count = 0 THEN
        RETURN ROW(false, 'NO_AUTHOR', '作者名单为空，不能发起确认')::op_result;
    END IF;
    IF v_b.paper_version_id IS NULL THEN
        RETURN ROW(false, 'NO_PAPER_VERSION', '缺少论文版本，不能发起确认')::op_result;
    END IF;

    UPDATE submission_batch
       SET status = 'PENDING_AUTHORS', frozen_at = now()
     WHERE batch_id = p_batch_id;

    INSERT INTO notification (account_id, category, title, body, link_url)
    SELECT a.account_id, 'CONFIRM',
           '待确认：' || v_b.title_snapshot,
           format('第 %s 轮汇交批次已发起，请审阅材料并确认。', v_b.round_no),
           '/batches/' || p_batch_id
      FROM batch_author ba
      JOIN account a ON a.person_id = ba.person_id
     WHERE ba.batch_id = p_batch_id;

    PERFORM fn_queue_mail(ba.person_id,
                          '【汇交平台】请确认论文批次：' || v_b.title_snapshot,
                          format('您好 %s，论文《%s》第 %s 轮汇交已发起确认，请登录平台处理。',
                                 ba.name_snapshot, v_b.title_snapshot, v_b.round_no),
                          'batch', p_batch_id)
      FROM batch_author ba
     WHERE ba.batch_id = p_batch_id;

    PERFORM fn_audit(p_actor_person_id, 'submission_batch', p_batch_id::text, 'START_CONFIRMATION', NULL);
    RETURN ROW(true, 'OK', format('已发起确认，等待 %s 位作者逐一确认', v_b.author_count))::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 作者确认 / 撤回 / 异议
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_record_confirmation(
    p_batch_id        bigint,
    p_person_id       bigint,
    p_action          text,
    p_comment         text DEFAULT NULL
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b          submission_batch%ROWTYPE;
    v_current    text;
    v_confirmed  integer;
    v_owner      bigint;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;

    IF v_b.status NOT IN ('PENDING_AUTHORS', 'READY_TO_SUBMIT') THEN
        RETURN ROW(false, 'BAD_STATE', '当前批次状态不允许确认或撤回')::op_result;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM batch_author
                    WHERE batch_id = p_batch_id AND person_id = p_person_id) THEN
        RETURN ROW(false, 'NOT_BATCH_AUTHOR', '您不在本批次作者名单中，不能确认')::op_result;
    END IF;

    SELECT action INTO v_current
      FROM confirmation
     WHERE batch_id = p_batch_id AND person_id = p_person_id AND is_current;

    IF p_action = 'CONFIRM' THEN
        IF v_current = 'CONFIRM' THEN
            RETURN ROW(true, 'NOOP', '您已确认，无需重复操作')::op_result;
        END IF;
    ELSIF p_action = 'WITHDRAW' THEN
        IF v_current IS DISTINCT FROM 'CONFIRM' THEN
            RETURN ROW(false, 'NOT_CONFIRMED', '当前没有您的有效确认，无法撤回')::op_result;
        END IF;
    ELSIF p_action = 'DISPUTE' THEN
        IF p_comment IS NULL OR btrim(p_comment) = '' THEN
            RETURN ROW(false, 'REASON_REQUIRED', '提出异议必须填写理由')::op_result;
        END IF;
    ELSE
        RETURN ROW(false, 'BAD_ACTION', '非法的确认操作')::op_result;
    END IF;

    UPDATE confirmation SET is_current = false
     WHERE batch_id = p_batch_id AND person_id = p_person_id AND is_current;

    INSERT INTO confirmation (batch_id, person_id, action, comment, is_current, created_by)
    VALUES (p_batch_id, p_person_id, p_action, p_comment, true, p_person_id);

    IF p_action = 'DISPUTE' THEN
        -- 本轮结束：其他作者的当前确认置为历史，批次进入"存在异议"
        UPDATE confirmation SET is_current = false
         WHERE batch_id = p_batch_id AND person_id <> p_person_id AND is_current;

        UPDATE submission_batch
           SET status = 'DISPUTED', ended_at = now(), ended_reason = 'DISPUTE'
         WHERE batch_id = p_batch_id;

        SELECT owner_snapshot INTO v_owner FROM submission_batch WHERE batch_id = p_batch_id;
        PERFORM fn_notify(v_owner, 'DISPUTE',
                          '批次存在异议：' || v_b.title_snapshot,
                          '有作者提出异议，本轮已结束，请处理后创建新批次。',
                          '/batches/' || p_batch_id);
        PERFORM fn_queue_mail(v_owner,
                              '【汇交平台】批次存在异议：' || v_b.title_snapshot,
                              '有作者提出异议，本轮确认已结束。', 'batch', p_batch_id);
        PERFORM fn_audit(p_person_id, 'submission_batch', p_batch_id::text, 'DISPUTE',
                         jsonb_build_object('reason', p_comment));
        RETURN ROW(true, 'DISPUTED', '已提出异议，本轮确认结束')::op_result;
    END IF;

    SELECT count(*) INTO v_confirmed
      FROM confirmation
     WHERE batch_id = p_batch_id AND is_current AND action = 'CONFIRM';

    IF v_confirmed >= v_b.author_count THEN
        UPDATE submission_batch SET status = 'READY_TO_SUBMIT' WHERE batch_id = p_batch_id;
        PERFORM fn_notify(v_b.owner_snapshot, 'READY',
                          '全部作者已确认：' || v_b.title_snapshot,
                          '可以提交管理员审核了。', '/batches/' || p_batch_id);
    ELSE
        UPDATE submission_batch SET status = 'PENDING_AUTHORS' WHERE batch_id = p_batch_id;
    END IF;

    -- 审计由 trg_audit_confirmation 统一写入（触发器兜底，任何直接写入也会留痕）

    RETURN ROW(true, 'OK',
               format('操作成功（%s/%s 已确认）', v_confirmed, v_b.author_count))::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 提交审核：原子校验 + 状态更新
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_submit_batch(
    p_batch_id        bigint,
    p_actor_person_id bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b          submission_batch%ROWTYPE;
    v_confirmed  integer;
    v_required   text;
    v_admin      record;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;

    IF v_b.owner_snapshot <> p_actor_person_id THEN
        RETURN ROW(false, 'FORBIDDEN', '只有论文负责人可以正式提交审核')::op_result;
    END IF;

    IF v_b.status = 'PENDING_AUTHORS' THEN
        RETURN ROW(false, 'NOT_ALL_CONFIRMED', '仍有作者未确认，不能提交审核')::op_result;
    END IF;
    IF v_b.status <> 'READY_TO_SUBMIT' THEN
        RETURN ROW(false, 'BAD_STATE', '当前批次状态不允许提交审核')::op_result;
    END IF;

    IF v_b.author_count = 0 THEN
        RETURN ROW(false, 'NO_AUTHOR', '作者名单为空，不能提交审核')::op_result;
    END IF;

    SELECT count(*) INTO v_confirmed
      FROM confirmation
     WHERE batch_id = p_batch_id AND is_current AND action = 'CONFIRM';

    IF v_confirmed <> v_b.author_count THEN
        RETURN ROW(false, 'NOT_ALL_CONFIRMED',
                   format('确认人数 %s / %s，不能提交审核', v_confirmed, v_b.author_count))::op_result;
    END IF;

    IF v_b.paper_version_id IS NULL THEN
        RETURN ROW(false, 'MISSING_PAPER_VERSION', '缺少论文版本，不能提交审核')::op_result;
    END IF;

    FOREACH v_required IN ARRAY ARRAY['CODE','RAW_DATA','CONFIG','LOG','RESULT'] LOOP
        IF NOT EXISTS (SELECT 1 FROM batch_material
                        WHERE batch_id = p_batch_id AND material_type = v_required) THEN
            RETURN ROW(false, 'MISSING_MATERIAL',
                       format('缺少必要材料类型：%s', v_required))::op_result;
        END IF;
    END LOOP;

    UPDATE submission_batch
       SET status = 'PENDING_ADMIN', submitted_at = now()
     WHERE batch_id = p_batch_id;

    FOR v_admin IN
        SELECT a.person_id, p.name
          FROM account a
          JOIN account_role ar ON ar.account_id = a.account_id
          JOIN person p ON p.person_id = a.person_id
         WHERE ar.role_code = 'INSTITUTE_ADMIN'
           AND ar.institute_id = v_b.institute_id
           AND ar.is_active
           AND a.is_enabled
    LOOP
        PERFORM fn_notify(v_admin.person_id, 'REVIEW',
                          '待审核：' || v_b.title_snapshot,
                          format('第 %s 轮批次已提交，请受理。', v_b.round_no),
                          '/admin/batches/' || p_batch_id);
        PERFORM fn_queue_mail(v_admin.person_id,
                              '【汇交平台】待审核批次：' || v_b.title_snapshot,
                              format('第 %s 轮批次已提交审核。', v_b.round_no),
                              'batch', p_batch_id);
    END LOOP;

    PERFORM fn_audit(p_actor_person_id, 'submission_batch', p_batch_id::text, 'SUBMIT', NULL);
    RETURN ROW(true, 'OK', '已提交，等待管理员受理')::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 负责人整体撤回
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_withdraw_batch(
    p_batch_id        bigint,
    p_actor_person_id bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b submission_batch%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;

    IF v_b.owner_snapshot <> p_actor_person_id THEN
        RETURN ROW(false, 'FORBIDDEN', '只有论文负责人可以整体撤回批次')::op_result;
    END IF;

    IF v_b.status NOT IN ('PENDING_AUTHORS', 'READY_TO_SUBMIT', 'PENDING_ADMIN') THEN
        RETURN ROW(false, 'BAD_STATE', '当前状态不允许撤回（审核中请由管理员退回）')::op_result;
    END IF;

    UPDATE submission_batch
       SET status = 'WITHDRAWN', ended_at = now(), ended_reason = 'WITHDRAW'
     WHERE batch_id = p_batch_id;

    PERFORM fn_audit(p_actor_person_id, 'submission_batch', p_batch_id::text, 'WITHDRAW', NULL);

    INSERT INTO notification (account_id, category, title, body, link_url)
    SELECT a.account_id, 'WITHDRAWN',
           '批次已撤回：' || v_b.title_snapshot,
           '负责人撤回了本轮汇交，记录已保留。', '/batches/' || p_batch_id
      FROM batch_author ba JOIN account a ON a.person_id = ba.person_id
     WHERE ba.batch_id = p_batch_id;

    RETURN ROW(true, 'OK', '批次已撤回，历史记录已保留')::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 管理员受理 / 审核
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_accept_batch(
    p_batch_id        bigint,
    p_admin_person_id bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b submission_batch%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;

    IF NOT (fn_is_institute_admin(p_admin_person_id, v_b.institute_id)
            OR fn_is_sys_admin(p_admin_person_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '只有主管研究所管理员可以受理该批次')::op_result;
    END IF;

    IF v_b.status <> 'PENDING_ADMIN' THEN
        RETURN ROW(false, 'BAD_STATE', '批次不在待审核状态，不能受理')::op_result;
    END IF;

    INSERT INTO admin_review (batch_id, action, reviewer_person_id, comment)
    VALUES (p_batch_id, 'ACCEPT', p_admin_person_id, NULL);

    UPDATE submission_batch SET status = 'UNDER_REVIEW' WHERE batch_id = p_batch_id;

    PERFORM fn_audit(p_admin_person_id, 'submission_batch', p_batch_id::text, 'ACCEPT', NULL);
    RETURN ROW(true, 'OK', '已受理，进入审核中')::op_result;
END;
$$;

CREATE OR REPLACE FUNCTION sp_review_batch(
    p_batch_id        bigint,
    p_admin_person_id bigint,
    p_decision        text,
    p_comment         text DEFAULT NULL
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b submission_batch%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;

    IF NOT (fn_is_institute_admin(p_admin_person_id, v_b.institute_id)
            OR fn_is_sys_admin(p_admin_person_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '只有主管研究所管理员可以审核该批次')::op_result;
    END IF;

    IF v_b.status <> 'UNDER_REVIEW' THEN
        RETURN ROW(false, 'BAD_STATE', '批次尚未受理或已结束')::op_result;
    END IF;

    IF p_decision NOT IN ('APPROVE', 'RETURN') THEN
        RETURN ROW(false, 'BAD_ACTION', '审核结论只能是通过或退回')::op_result;
    END IF;

    IF p_decision = 'RETURN' AND (p_comment IS NULL OR btrim(p_comment) = '') THEN
        RETURN ROW(false, 'REASON_REQUIRED', '退回必须填写审核意见')::op_result;
    END IF;

    INSERT INTO admin_review (batch_id, action, reviewer_person_id, comment)
    VALUES (p_batch_id, p_decision, p_admin_person_id, p_comment);

    UPDATE submission_batch
       SET status = CASE p_decision WHEN 'APPROVE' THEN 'ARCHIVED' ELSE 'RETURNED' END,
           ended_at = now(),
           ended_reason = p_decision
     WHERE batch_id = p_batch_id;

    PERFORM fn_notify(v_b.owner_snapshot,
                      CASE p_decision WHEN 'APPROVE' THEN 'ARCHIVED' ELSE 'RETURNED' END,
                      CASE p_decision WHEN 'APPROVE' THEN '批次已归档：' ELSE '批次被退回：' END || v_b.title_snapshot,
                      COALESCE(p_comment, '管理员已通过并归档。'),
                      '/batches/' || p_batch_id);
    PERFORM fn_queue_mail(v_b.owner_snapshot,
                          '【汇交平台】审核结果：' || v_b.title_snapshot,
                          COALESCE(p_comment, ''), 'batch', p_batch_id);

    PERFORM fn_audit(p_admin_person_id, 'submission_batch', p_batch_id::text, p_decision,
                     jsonb_build_object('comment', p_comment));
    RETURN ROW(true, 'OK',
               CASE p_decision WHEN 'APPROVE' THEN '审核通过，已归档' ELSE '已退回，负责人可创建新批次' END)::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 提醒 / 催办（提高项）
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_remind_batch(
    p_batch_id        bigint,
    p_actor_person_id bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_b     submission_batch%ROWTYPE;
    v_count integer;
BEGIN
    SELECT * INTO v_b FROM submission_batch WHERE batch_id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '批次不存在')::op_result; END IF;
    IF v_b.status NOT IN ('PENDING_AUTHORS', 'READY_TO_SUBMIT') THEN
        RETURN ROW(false, 'BAD_STATE', '只有确认阶段的批次可以发送提醒')::op_result;
    END IF;
    IF NOT (v_b.owner_snapshot = p_actor_person_id
            OR fn_is_paper_maintainer(p_actor_person_id, v_b.paper_id)
            OR fn_is_institute_admin(p_actor_person_id, v_b.institute_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '无权发送提醒')::op_result;
    END IF;

    SELECT count(*) INTO v_count
      FROM v_author_todo t
     WHERE t.batch_id = p_batch_id AND t.current_state <> 'CONFIRM';

    INSERT INTO notification (account_id, category, title, body, link_url)
    SELECT a.account_id, 'REMIND',
           '催办：' || v_b.title_snapshot,
           '请尽快完成本轮确认。', '/batches/' || p_batch_id
      FROM v_author_todo t
      JOIN account a ON a.person_id = t.person_id
     WHERE t.batch_id = p_batch_id AND t.current_state <> 'CONFIRM';

    INSERT INTO mail_outbox (to_email, subject, body, related_type, related_id)
    SELECT per.email, '【汇交平台】催办：' || v_b.title_snapshot,
           '您有一轮汇交确认待处理。', 'batch', p_batch_id
      FROM v_author_todo t JOIN person per ON per.person_id = t.person_id
     WHERE t.batch_id = p_batch_id AND t.current_state <> 'CONFIRM';

    PERFORM fn_audit(p_actor_person_id, 'submission_batch', p_batch_id::text, 'REMIND',
                     jsonb_build_object('targets', v_count));
    RETURN ROW(true, 'OK', format('已向 %s 位未确认作者发送提醒', v_count))::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 访问申请 / 审批 / 授权 / 下载
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_apply_access(
    p_account_id          bigint,
    p_material_version_id bigint,
    p_reason              text
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_paper_id bigint;
    v_inst     bigint;
    v_admin    record;
    v_req_id   bigint;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RETURN ROW(false, 'REASON_REQUIRED', '请填写申请理由')::op_result;
    END IF;

    SELECT m.paper_id, p.institute_id INTO v_paper_id, v_inst
      FROM material_version mv
      JOIN material m ON m.material_id = mv.material_id
      JOIN paper p ON p.paper_id = m.paper_id
     WHERE mv.material_version_id = p_material_version_id;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '材料版本不存在')::op_result; END IF;

    IF fn_can_view_material(p_account_id, p_material_version_id) THEN
        RETURN ROW(false, 'ALREADY_ACCESSIBLE', '您已拥有该材料的访问权限，无需申请')::op_result;
    END IF;

    -- 同一账号对同一材料版本只允许一条待审批申请，避免重复提交刷屏
    IF EXISTS (
        SELECT 1 FROM access_request
         WHERE requester_account_id = p_account_id
           AND material_version_id = p_material_version_id
           AND status = 'PENDING'
    ) THEN
        RETURN ROW(false, 'ALREADY_PENDING', '该材料已有待审批的申请，请等待管理员处理')::op_result;
    END IF;

    INSERT INTO access_request (requester_account_id, material_version_id, reason)
    VALUES (p_account_id, p_material_version_id, p_reason)
    RETURNING request_id INTO v_req_id;

    FOR v_admin IN
        SELECT a.person_id
          FROM account a
          JOIN account_role ar ON ar.account_id = a.account_id
         WHERE ar.role_code = 'INSTITUTE_ADMIN'
           AND ar.institute_id = v_inst
           AND ar.is_active AND a.is_enabled
    LOOP
        PERFORM fn_notify(v_admin.person_id, 'ACCESS_REQUEST',
                          '新的材料访问申请', p_reason,
                          '/admin/access/' || v_req_id);
    END LOOP;

    PERFORM fn_audit((SELECT person_id FROM account WHERE account_id = p_account_id),
                     'access_request', v_req_id::text, 'APPLY',
                     jsonb_build_object('material_version_id', p_material_version_id));
    RETURN ROW(true, 'OK', '申请已提交，等待管理员审批')::op_result;
END;
$$;

CREATE OR REPLACE FUNCTION sp_decide_access(
    p_request_id      bigint,
    p_admin_person_id bigint,
    p_approve         boolean,
    p_comment         text DEFAULT NULL,
    p_days            integer DEFAULT 7,
    p_max_downloads   integer DEFAULT NULL
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_r    access_request%ROWTYPE;
    v_inst bigint;
    v_requester bigint;
BEGIN
    SELECT * INTO v_r FROM access_request WHERE request_id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '申请不存在')::op_result; END IF;
    IF v_r.status <> 'PENDING' THEN
        RETURN ROW(false, 'BAD_STATE', '该申请已处理')::op_result;
    END IF;

    SELECT p.institute_id INTO v_inst
      FROM material_version mv
      JOIN material m ON m.material_id = mv.material_id
      JOIN paper p ON p.paper_id = m.paper_id
     WHERE mv.material_version_id = v_r.material_version_id;

    IF NOT (fn_is_institute_admin(p_admin_person_id, v_inst)
            OR fn_is_sys_admin(p_admin_person_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '只有主管研究所管理员可以审批该申请')::op_result;
    END IF;

    IF p_days IS NOT NULL AND p_days <= 0 THEN
        RETURN ROW(false, 'BAD_PARAM', '授权有效期必须大于 0 天')::op_result;
    END IF;

    UPDATE access_request
       SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
           decided_by = p_admin_person_id,
           decided_at = now(),
           decision_comment = p_comment
     WHERE request_id = p_request_id;

    IF p_approve THEN
        INSERT INTO access_grant (request_id, account_id, material_version_id,
                                  scope, valid_from, valid_to, max_downloads)
        VALUES (p_request_id, v_r.requester_account_id, v_r.material_version_id,
                'DOWNLOAD', now(), now() + make_interval(days => COALESCE(p_days, 7)),
                p_max_downloads);
    END IF;

    SELECT a.person_id INTO v_requester FROM account a WHERE a.account_id = v_r.requester_account_id;
    PERFORM fn_notify(v_requester, 'ACCESS_DECISION',
                      CASE WHEN p_approve THEN '访问申请已批准' ELSE '访问申请被拒绝' END,
                      COALESCE(p_comment, ''), '/access');
    PERFORM fn_audit(p_admin_person_id, 'access_request', p_request_id::text,
                     CASE WHEN p_approve THEN 'APPROVE' ELSE 'REJECT' END,
                     jsonb_build_object('comment', p_comment, 'days', p_days));
    RETURN ROW(true, 'OK', CASE WHEN p_approve THEN '已批准并生成授权' ELSE '已拒绝' END)::op_result;
END;
$$;

CREATE OR REPLACE FUNCTION sp_revoke_grant(
    p_grant_id        bigint,
    p_admin_person_id bigint,
    p_reason          text DEFAULT NULL
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_g access_grant%ROWTYPE;
    v_inst bigint;
BEGIN
    SELECT * INTO v_g FROM access_grant WHERE grant_id = p_grant_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '授权不存在')::op_result; END IF;
    IF v_g.revoked_at IS NOT NULL THEN
        RETURN ROW(true, 'NOOP', '该授权已撤销')::op_result;
    END IF;

    SELECT p.institute_id INTO v_inst
      FROM material_version mv
      JOIN material m ON m.material_id = mv.material_id
      JOIN paper p ON p.paper_id = m.paper_id
     WHERE mv.material_version_id = v_g.material_version_id;

    IF NOT (fn_is_institute_admin(p_admin_person_id, v_inst)
            OR fn_is_sys_admin(p_admin_person_id)) THEN
        RETURN ROW(false, 'FORBIDDEN', '无权撤销该授权')::op_result;
    END IF;

    UPDATE access_grant
       SET revoked_at = now(), revoked_by = p_admin_person_id
     WHERE grant_id = p_grant_id;

    PERFORM fn_audit(p_admin_person_id, 'access_grant', p_grant_id::text, 'REVOKE',
                     jsonb_build_object('reason', p_reason));
    RETURN ROW(true, 'OK', '授权已撤销')::op_result;
END;
$$;

-- 原子下载：校验授权、计数、写访问日志
CREATE OR REPLACE FUNCTION sp_register_download(
    p_grant_id   bigint,
    p_ip         text DEFAULT NULL
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_g access_grant%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM access_grant WHERE grant_id = p_grant_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '授权不存在')::op_result; END IF;
    IF v_g.revoked_at IS NOT NULL THEN
        RETURN ROW(false, 'REVOKED', '授权已撤销')::op_result;
    END IF;
    IF now() < v_g.valid_from OR now() > v_g.valid_to THEN
        RETURN ROW(false, 'EXPIRED', '授权不在有效期内')::op_result;
    END IF;
    IF v_g.max_downloads IS NOT NULL AND v_g.download_count >= v_g.max_downloads THEN
        RETURN ROW(false, 'EXHAUSTED', '下载次数已用尽')::op_result;
    END IF;

    UPDATE access_grant
       SET download_count = download_count + 1
     WHERE grant_id = p_grant_id;

    INSERT INTO access_log (account_id, material_version_id, grant_id, action, detail)
    VALUES (v_g.account_id, v_g.material_version_id, p_grant_id, 'DOWNLOAD', p_ip);

    RETURN ROW(true, 'OK', '下载已记录')::op_result;
END;
$$;

-- -----------------------------------------------------------------------------
-- 维护成员授权
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_grant_maintainer(
    p_paper_id   bigint,
    p_person_id  bigint,
    p_scope      text,
    p_actor      bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
DECLARE
    v_paper paper%ROWTYPE;
BEGIN
    SELECT * INTO v_paper FROM paper WHERE paper_id = p_paper_id FOR UPDATE;
    IF NOT FOUND THEN RETURN ROW(false, 'NOT_FOUND', '论文不存在')::op_result; END IF;
    IF v_paper.owner_person_id <> p_actor THEN
        RETURN ROW(false, 'FORBIDDEN', '只有负责人可以授予维护权限')::op_result;
    END IF;
    IF p_scope NOT IN ('ALL','MATERIAL','EXPERIMENT') THEN
        RETURN ROW(false, 'BAD_PARAM', '非法授权范围')::op_result;
    END IF;
    IF p_person_id = v_paper.owner_person_id THEN
        RETURN ROW(false, 'BAD_PARAM', '负责人无需重复授权')::op_result;
    END IF;

    INSERT INTO paper_maintainer (paper_id, person_id, scope, granted_by, revoked_at)
    VALUES (p_paper_id, p_person_id, p_scope, p_actor, NULL)
    ON CONFLICT (paper_id, person_id)
    DO UPDATE SET scope = EXCLUDED.scope, granted_by = EXCLUDED.granted_by,
                  granted_at = now(), revoked_at = NULL;

    PERFORM fn_audit(p_actor, 'paper_maintainer', p_paper_id::text || ':' || p_person_id::text,
                     'GRANT', jsonb_build_object('scope', p_scope));
    RETURN ROW(true, 'OK', '维护权限已授予')::op_result;
END;
$$;

CREATE OR REPLACE FUNCTION sp_revoke_maintainer(
    p_paper_id  bigint,
    p_person_id bigint,
    p_actor     bigint
) RETURNS op_result LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM paper WHERE paper_id = p_paper_id AND owner_person_id = p_actor) THEN
        RETURN ROW(false, 'FORBIDDEN', '只有负责人可以撤销维护权限')::op_result;
    END IF;
    UPDATE paper_maintainer
       SET revoked_at = now()
     WHERE paper_id = p_paper_id AND person_id = p_person_id AND revoked_at IS NULL;
    PERFORM fn_audit(p_actor, 'paper_maintainer', p_paper_id::text || ':' || p_person_id::text,
                     'REVOKE', NULL);
    RETURN ROW(true, 'OK', '维护权限已撤销')::op_result;
END;
$$;
