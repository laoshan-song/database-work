-- =============================================================================
--  06_seed.sql  —— 初始化演示数据
--  依赖：01~05 已执行；使用内置 sha256()，不需要额外扩展
--
--  演示数据覆盖验收要求：
--    * 1 个研究所（另加 1 个对照研究所）+ 9 个人员账号
--    * 论文 A：4 位作者（3 内部 + 1 外部），已完成"退回 -> 补充 -> 归档"两轮
--    * 论文 B：另一研究所的受限项目，用于越权对照
--    * 论文 C：草稿批次，用于现场完整演示
--    * 材料、实验运行、结果追溯、授权下载、待审批申请
--
--  演示账号统一密码：Demo@2026
-- =============================================================================
SET search_path TO srdp, public;
SET client_min_messages = warning;

-- 生成一条文件元数据；文件内容约定为 'SRDP-DEMO:' || storage_key
-- scripts/init_db.py 会按同一约定写出真实文件，保证 SHA-256 一致
CREATE OR REPLACE FUNCTION pg_temp.mock_file(
    p_key      text,
    p_name     text,
    p_fmt      text,
    p_uploader bigint
) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO file_object (storage_key, original_name, file_format, size_bytes, sha256, uploaded_by)
    VALUES (p_key, p_name, p_fmt,
            octet_length('SRDP-DEMO:' || p_key),
            encode(sha256(convert_to('SRDP-DEMO:' || p_key, 'UTF8')), 'hex'),
            p_uploader)
    RETURNING file_id;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.mock_material(
    p_paper    bigint,
    p_type     text,
    p_name     text,
    p_desc     text,
    p_version  integer,
    p_file     bigint,
    p_uploader bigint,
    p_note     text
) RETURNS bigint LANGUAGE sql AS $f$
    WITH m AS (
        INSERT INTO material (paper_id, material_type, name, description)
        VALUES (p_paper, p_type, p_name, p_desc)
        RETURNING material_id
    )
    INSERT INTO material_version (material_id, version_no, file_id, sha256, change_note, created_by)
    SELECT material_id, p_version, p_file, NULL, p_note, p_uploader FROM m
    RETURNING material_version_id;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.mock_version(
    p_material bigint,
    p_version  integer,
    p_file     bigint,
    p_uploader bigint,
    p_note     text
) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO material_version (material_id, version_no, file_id, sha256, change_note, created_by)
    VALUES (p_material, p_version, p_file, NULL, p_note, p_uploader)
    RETURNING material_version_id;
$f$;

DO $$
DECLARE
    -- 机构 / 人员 / 账号
    v_inst1 bigint; v_inst2 bigint;
    v_p_admin bigint; v_p_owner bigint; v_p_a2 bigint; v_p_a3 bigint;
    v_p_a4 bigint; v_p_user bigint; v_p_ops bigint; v_p_liu bigint; v_p_zheng bigint;
    v_acc_admin bigint; v_acc_owner bigint; v_acc_a2 bigint; v_acc_a3 bigint;
    v_acc_a4 bigint; v_acc_user bigint; v_acc_ops bigint; v_acc_liu bigint; v_acc_zheng bigint;

    -- 论文 A
    v_paper bigint;
    v_f_pv1 bigint; v_f_pv2 bigint;
    v_pv1 bigint; v_pv2 bigint;
    v_mat_code bigint; v_mat_data bigint; v_mat_dict bigint; v_mat_conf bigint;
    v_mat_log bigint; v_mat_res bigint; v_mat_fig bigint; v_mat_notes bigint;
    v_f_code bigint; v_f_data bigint; v_f_dict bigint; v_f_conf bigint;
    v_f_log bigint; v_f_res1 bigint; v_f_res2 bigint; v_f_fig bigint;
    v_f_notes1 bigint; v_f_notes2 bigint;
    v_mv_code bigint; v_mv_data bigint; v_mv_dict bigint; v_mv_conf bigint;
    v_mv_log bigint; v_mv_res1 bigint; v_mv_res2 bigint; v_mv_fig bigint;
    v_mv_notes1 bigint; v_mv_notes2 bigint;
    v_task bigint; v_run1 bigint; v_run2 bigint;

    -- 论文 B / C
    v_paper2 bigint; v_paper3 bigint;
    v_f_b_code bigint; v_f_b_data bigint;
    v_mv_b_code bigint; v_mv_b_data bigint;
    v_f_c_pv bigint; v_f_c_code bigint; v_f_c_data bigint; v_f_c_conf bigint;
    v_f_c_log bigint; v_f_c_res bigint; v_f_c_notes bigint;
    v_pv_c bigint; v_mv_c_code bigint; v_mv_c_data bigint; v_mv_c_conf bigint;
    v_mv_c_log bigint; v_mv_c_res bigint; v_mv_c_notes bigint;
    v_task_c bigint; v_batch_c bigint;

    -- 批次 / 申请
    v_b1 bigint; v_b2 bigint;
    v_req_raw bigint; v_req_fig bigint;
    v_r op_result;
BEGIN
    ---------------------------------------------------------------------------
    -- 1. 研究所
    ---------------------------------------------------------------------------
    INSERT INTO institute (code, name, intro, contact_email)
    VALUES ('INST-01', '智能计算研究所', '面向智能计算与数据科学的基础研究机构（演示数据）', 'office@ica.example.org')
    RETURNING institute_id INTO v_inst1;

    INSERT INTO institute (code, name, intro, contact_email)
    VALUES ('INST-02', '数据科学研究中心', '对照研究所：用于验证跨所权限隔离（演示数据）', 'office@ds.example.org')
    RETURNING institute_id INTO v_inst2;

    ---------------------------------------------------------------------------
    -- 2. 人员
    ---------------------------------------------------------------------------
    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('A0001', '张伟', 'zhangwei@ica.example.org', '13800000001', 'STAFF', '研究员', v_inst1, DATE '2018-03-01')
    RETURNING person_id INTO v_p_admin;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('R0001', '李娜', 'lina@ica.example.org', '13800000002', 'RESEARCHER', '副研究员', v_inst1, DATE '2019-09-01')
    RETURNING person_id INTO v_p_owner;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('R0002', '王强', 'wangqiang@ica.example.org', '13800000003', 'RESEARCHER', '助理研究员', v_inst1, DATE '2020-07-01')
    RETURNING person_id INTO v_p_a2;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('S0001', '陈静', 'chenjing@ica.example.org', '13800000004', 'STUDENT', '博士研究生', v_inst1, DATE '2022-09-01')
    RETURNING person_id INTO v_p_a3;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('E0001', '赵磊', 'zhaolei@eastdata.example.com', '13900000005', 'EXTERNAL', '高级工程师', NULL, DATE '2023-01-01')
    RETURNING person_id INTO v_p_a4;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('R0003', '孙浩', 'sunhao@ica.example.org', '13800000006', 'RESEARCHER', '工程师', v_inst1, DATE '2021-04-01')
    RETURNING person_id INTO v_p_user;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('A0002', '周运维', 'zhouops@ica.example.org', '13800000007', 'STAFF', '系统管理员', v_inst1, DATE '2020-01-01')
    RETURNING person_id INTO v_p_ops;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('D0001', '刘敏', 'liumin@ds.example.org', '13900000008', 'RESEARCHER', '研究员', v_inst2, DATE '2017-09-01')
    RETURNING person_id INTO v_p_liu;

    INSERT INTO person (employee_no, name, email, phone, person_category, title_grade, home_institute_id, join_date)
    VALUES ('D0002', '郑凯', 'zhengkai@ds.example.org', '13900000009', 'STAFF', '管理员', v_inst2, DATE '2019-01-01')
    RETURNING person_id INTO v_p_zheng;

    UPDATE institute SET head_person_id = v_p_admin WHERE institute_id = v_inst1;
    UPDATE institute SET head_person_id = v_p_liu   WHERE institute_id = v_inst2;

    ---------------------------------------------------------------------------
    -- 3. 任职关系（含跨所任职有效期，提高项）
    ---------------------------------------------------------------------------
    INSERT INTO person_affiliation (person_id, institute_id, role_title, valid_from, is_primary) VALUES
        (v_p_admin, v_inst1, '所长',       DATE '2018-03-01', true),
        (v_p_owner, v_inst1, '副研究员',   DATE '2019-09-01', true),
        (v_p_a2,    v_inst1, '助理研究员', DATE '2020-07-01', true),
        (v_p_a3,    v_inst1, '博士研究生', DATE '2022-09-01', true),
        (v_p_user,  v_inst1, '工程师',     DATE '2021-04-01', true),
        (v_p_ops,   v_inst1, '系统管理员', DATE '2020-01-01', true),
        (v_p_liu,   v_inst2, '研究员',     DATE '2017-09-01', true),
        (v_p_zheng, v_inst2, '管理员',     DATE '2019-01-01', true);

    -- 王强跨所任职（有效期示例，已结束的兼职不授予当前访问权）
    INSERT INTO person_affiliation (person_id, institute_id, role_title, valid_from, valid_to, is_primary)
    VALUES (v_p_a2, v_inst2, '客座研究人员', DATE '2023-01-01', DATE '2024-12-31', false);

    ---------------------------------------------------------------------------
    -- 4. 账号（密码统一 Demo@2026，PBKDF2-SHA256 600000 轮）
    ---------------------------------------------------------------------------
    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_admin, 'admin',
            'pbkdf2:sha256:600000$3TfNrsQSdiM2YmA3$74ed4aa9834d781b12f164c4991e3294b38076bd6ce16309590d0c9b455145e8')
    RETURNING account_id INTO v_acc_admin;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_owner, 'lina',
            'pbkdf2:sha256:600000$qCZoqh3iGujyQRSY$886d600bd3dc35fe6aeb51c12abceaaf8657596f9ce8df6d774b02f9f32f220f')
    RETURNING account_id INTO v_acc_owner;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_a2, 'wangqiang',
            'pbkdf2:sha256:600000$BY2o6X8f0yqwnMR0$373d5bec59664fdaa07b7609d925ad9e3646669ab965dbd3f59e444968d00d89')
    RETURNING account_id INTO v_acc_a2;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_a3, 'chenjing',
            'pbkdf2:sha256:600000$UnwMlvA9zmbpFVJO$abdc2d1252dd6f5c4dac0eaaed78d85de7e84e0df1afc6fb69cfb6737e12a134')
    RETURNING account_id INTO v_acc_a3;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_a4, 'zhaolei',
            'pbkdf2:sha256:600000$dGlJ7516qrQ8cvsv$fab2bfbfe37318ed92cfa5271297247d098085ca8df9cd519e8e750b18f3a6c1')
    RETURNING account_id INTO v_acc_a4;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_user, 'sunhao',
            'pbkdf2:sha256:600000$xKtlq5OV9oSJvV1D$b297e10a81f3011bff18d552b46830aaacf20cf7c9ca965843a59ec58172f302')
    RETURNING account_id INTO v_acc_user;

    INSERT INTO account (person_id, username, password_hash, is_system_admin)
    VALUES (v_p_ops, 'ops',
            'pbkdf2:sha256:600000$s4hwhL7wArF0VKGF$b52f42e972bd1fc073b1872c7697fa6ffff2270997bcb4b777eb71794ef00d85', true)
    RETURNING account_id INTO v_acc_ops;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_liu, 'liumin',
            'pbkdf2:sha256:600000$qCZoqh3iGujyQRSY$886d600bd3dc35fe6aeb51c12abceaaf8657596f9ce8df6d774b02f9f32f220f')
    RETURNING account_id INTO v_acc_liu;

    INSERT INTO account (person_id, username, password_hash)
    VALUES (v_p_zheng, 'zhengkai',
            'pbkdf2:sha256:600000$kmOL6d8gOIGrSMG6$e096ec9d222d865ba4ab2fd5745290b5b743391d461ac27c7516e269f179ec86')
    RETURNING account_id INTO v_acc_zheng;

    ---------------------------------------------------------------------------
    -- 5. 角色
    ---------------------------------------------------------------------------
    INSERT INTO account_role (account_id, role_code, institute_id, granted_by, reason) VALUES
        (v_acc_admin, 'INSTITUTE_ADMIN', v_inst1, v_p_admin, '演示数据：研究所管理员'),
        (v_acc_zheng, 'INSTITUTE_ADMIN', v_inst2, v_p_zheng, '演示数据：对照研究所管理员'),
        (v_acc_user,  'DATA_USER',       NULL,     v_p_admin, '演示数据：数据使用者'),
        (v_acc_ops,   'SYS_ADMIN',       NULL,     v_p_admin, '演示数据：平台运维');

    ---------------------------------------------------------------------------
    -- 6. 论文 A：主演示论文（4 位作者，3 内部 + 1 外部）
    ---------------------------------------------------------------------------
    INSERT INTO paper (institute_id, owner_person_id, title, abstract, keywords,
                       research_field, venue, submission_status, doi, visibility_level)
    VALUES (v_inst1, v_p_owner,
            '面向科研数据汇交的多版本溯源方法研究',
            '提出一种以批次快照为核心的多版本材料溯源方法，保证汇交内容的可重现性与审计完整性。',
            '科研数据汇交;版本溯源;批次快照;审计',
            '数据管理', 'Journal of Data Science（拟投稿）', 'SUBMITTED', NULL, 'RESTRICTED')
    RETURNING paper_id INTO v_paper;

    INSERT INTO paper_author (paper_id, person_id, author_order, is_corresponding, is_external, affiliation_text) VALUES
        (v_paper, v_p_owner, 1, true,  false, '智能计算研究所'),
        (v_paper, v_p_a2,    2, false, false, '智能计算研究所'),
        (v_paper, v_p_a3,    3, false, false, '智能计算研究所'),
        (v_paper, v_p_a4,    4, false, true,  '华东数据科技有限公司');

    -- 授权维护成员：陈静可登记实验（不获得作者确认权）
    INSERT INTO paper_maintainer (paper_id, person_id, scope, granted_by)
    VALUES (v_paper, v_p_a3, 'EXPERIMENT', v_p_owner);

    ---------------------------------------------------------------------------
    -- 7. 论文 A：论文版本与材料版本
    ---------------------------------------------------------------------------
    v_f_pv1 := pg_temp.mock_file('demo/p1/manuscript_v1.pdf', 'manuscript_v1.pdf', 'pdf', v_p_owner);

    INSERT INTO paper_version (paper_id, version_no, stage, file_id, change_note, created_by)
    VALUES (v_paper, 1, 'SUBMISSION', v_f_pv1, '首次投稿稿', v_p_owner)
    RETURNING paper_version_id INTO v_pv1;

    v_f_code  := pg_temp.mock_file('demo/p1/analysis.py',   'analysis.py',   'py',   v_p_owner);
    v_f_data  := pg_temp.mock_file('demo/p1/raw_data.csv',  'raw_data.csv',  'csv',  v_p_owner);
    v_f_dict  := pg_temp.mock_file('demo/p1/data_dict.md',  'data_dict.md',  'md',   v_p_owner);
    v_f_conf  := pg_temp.mock_file('demo/p1/config.yaml',   'config.yaml',   'yaml', v_p_owner);
    v_f_log   := pg_temp.mock_file('demo/p1/run_r1.log',    'run_r1.log',    'log',  v_p_owner);
    v_f_res1  := pg_temp.mock_file('demo/p1/metrics_v1.json','metrics_v1.json','json',v_p_owner);
    v_f_fig   := pg_temp.mock_file('demo/p1/figure3.png',   'figure3.png',   'png',  v_p_owner);
    v_f_notes1:= pg_temp.mock_file('demo/p1/env_v1.md',     'env_v1.md',     'md',   v_p_owner);

    v_mv_code  := pg_temp.mock_material(v_paper, 'CODE',     '分析代码',   '实验主程序与依赖清单', 1, v_f_code,  v_p_owner, '初始版本');
    v_mv_data  := pg_temp.mock_material(v_paper, 'RAW_DATA', '实验原始数据', '实验采集的原始数据集', 1, v_f_data,  v_p_owner, '初始版本');
    v_mv_dict  := pg_temp.mock_material(v_paper, 'DATA_DICT','数据字典',   '字段含义与取值说明',   1, v_f_dict,  v_p_owner, '初始版本');
    v_mv_conf  := pg_temp.mock_material(v_paper, 'CONFIG',   '实验配置',   '超参数与运行配置',     1, v_f_conf,  v_p_owner, '初始版本');
    v_mv_log   := pg_temp.mock_material(v_paper, 'LOG',      '运行日志',   '第 1 次运行完整日志',  1, v_f_log,   v_p_owner, '初始版本');
    v_mv_res1  := pg_temp.mock_material(v_paper, 'RESULT',   '结果指标',   '准确率与耗时指标',     1, v_f_res1,  v_p_owner, '初始版本');
    v_mv_fig   := pg_temp.mock_material(v_paper, 'FIGURE',   '图3 对比曲线','论文图 3 的数据来源',  1, v_f_fig,   v_p_owner, '初始版本');
    v_mv_notes1:= pg_temp.mock_material(v_paper, 'NOTES',    '运行环境说明','软硬件环境说明',       1, v_f_notes1,v_p_owner, '初始版本');

    ---------------------------------------------------------------------------
    -- 8. 论文 A：实验任务与第 1 次运行（环境说明缺少 CUDA 版本）
    ---------------------------------------------------------------------------
    INSERT INTO experiment_task (paper_id, title, purpose, scheme, metrics, created_by)
    VALUES (v_paper, '多版本材料一致性验证实验',
            '验证不同版本组合下结果的可重现性',
            '固定随机种子，分别使用 v1 代码与 v1 数据运行 3 次，比较指标波动',
            '准确率、F1、单次运行耗时', v_p_owner)
    RETURNING task_id INTO v_task;

    INSERT INTO experiment_run (task_id, run_label, code_version_id, data_version_id,
                                config_version_id, log_version_id, parameters,
                                hardware_env, software_env, started_at, ended_at, status, created_by)
    VALUES (v_task, 'R1', v_mv_code, v_mv_data, v_mv_conf, v_mv_log,
            '{"epochs": 50, "lr": 0.001, "batch_size": 32, "seed": 42}'::jsonb,
            'CPU: 32 cores / 128 GB RAM; GPU: NVIDIA A100 40GB',
            'Python 3.12.4; PyTorch 2.4.1',
            now() - interval '10 days', now() - interval '10 days' + interval '2 hours 35 minutes',
            'SUCCESS', v_p_owner)
    RETURNING run_id INTO v_run1;

    INSERT INTO experiment_result (run_id, result_version_id, metric_summary, paper_figure_no, conclusion)
    VALUES (v_run1, v_mv_res1, '准确率 0.923，F1 0.918，耗时 2h35m', '图3', '版本组合可稳定复现实验结果');

    ---------------------------------------------------------------------------
    -- 9. 论文 A：第 1 轮批次 —— 3/4 确认 -> 提交 -> 受理 -> 退回
    ---------------------------------------------------------------------------
    v_r := sp_create_batch(v_paper, v_p_owner);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch1 create: %', v_r.message; END IF;
    SELECT batch_id INTO v_b1 FROM submission_batch WHERE paper_id = v_paper AND round_no = 1;

    v_r := sp_start_confirmation(v_b1, v_p_owner);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch1 start: %', v_r.message; END IF;

    v_r := sp_record_confirmation(v_b1, v_p_owner, 'CONFIRM', '作为负责人确认本轮材料');
    v_r := sp_record_confirmation(v_b1, v_p_a2,    'CONFIRM', '数据与代码版本已核对');
    v_r := sp_record_confirmation(v_b1, v_p_a3,    'CONFIRM', '同意');

    -- 此时进度为 3/4，负责人提交会被拒绝（演示点；此处不中断初始化）
    v_r := sp_submit_batch(v_b1, v_p_owner);
    IF v_r.ok THEN RAISE EXCEPTION 'seed: 未全员确认竟然提交成功'; END IF;

    v_r := sp_record_confirmation(v_b1, v_p_a4, 'CONFIRM', '外部作者确认，材料范围无异议');
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch1 confirm4: %', v_r.message; END IF;

    v_r := sp_submit_batch(v_b1, v_p_owner);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch1 submit: %', v_r.message; END IF;

    v_r := sp_accept_batch(v_b1, v_p_admin);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch1 accept: %', v_r.message; END IF;

    v_r := sp_review_batch(v_b1, v_p_admin, 'RETURN',
                           '运行环境说明缺少关键软件版本（CUDA），请补充后重新提交。');
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch1 return: %', v_r.message; END IF;

    ---------------------------------------------------------------------------
    -- 10. 补充材料：环境说明 v2、论文稿 v2、补充运行 R2、结果 v2
    ---------------------------------------------------------------------------
    v_f_notes2 := pg_temp.mock_file('demo/p1/env_v2.md', 'env_v2.md', 'md', v_p_owner);
    v_mv_notes2 := pg_temp.mock_version(
        (SELECT material_id FROM material WHERE paper_id = v_paper AND name = '运行环境说明'),
        2, v_f_notes2, v_p_owner,
        '补充 CUDA 12.4、驱动版本与完整依赖清单');

    v_f_res2 := pg_temp.mock_file('demo/p1/metrics_v2.json', 'metrics_v2.json', 'json', v_p_owner);
    v_mv_res2 := pg_temp.mock_version(
        (SELECT material_id FROM material WHERE paper_id = v_paper AND name = '结果指标'),
        2, v_f_res2, v_p_owner,
        '补充 R2 运行指标与方差分析');

    INSERT INTO experiment_run (task_id, run_label, code_version_id, data_version_id,
                                config_version_id, log_version_id, parameters,
                                hardware_env, software_env, started_at, ended_at, status, created_by)
    VALUES (v_task, 'R2', v_mv_code, v_mv_data, v_mv_conf, v_mv_log,
            '{"epochs": 50, "lr": 0.001, "batch_size": 32, "seed": 2026}'::jsonb,
            'CPU: 32 cores / 128 GB RAM; GPU: NVIDIA A100 40GB',
            'Python 3.12.4; PyTorch 2.4.1; CUDA 12.4; NVIDIA Driver 550.54',
            now() - interval '3 days', now() - interval '3 days' + interval '2 hours 48 minutes',
            'SUCCESS', v_p_owner)
    RETURNING run_id INTO v_run2;

    INSERT INTO experiment_result (run_id, result_version_id, metric_summary, paper_figure_no, conclusion)
    VALUES (v_run2, v_mv_res2, '准确率 0.926，F1 0.921，耗时 2h48m', '图3', '补充运行与 R1 结论一致');

    v_f_pv2 := pg_temp.mock_file('demo/p1/manuscript_v2.pdf', 'manuscript_v2.pdf', 'pdf', v_p_owner);
    INSERT INTO paper_version (paper_id, version_no, stage, file_id, change_note, created_by)
    VALUES (v_paper, 2, 'REVISION', v_f_pv2, '按审核意见补充环境与复现说明', v_p_owner)
    RETURNING paper_version_id INTO v_pv2;

    ---------------------------------------------------------------------------
    -- 11. 论文 A：第 2 轮批次 —— 全员确认 -> 提交 -> 受理 -> 通过归档
    ---------------------------------------------------------------------------
    v_r := sp_create_batch(v_paper, v_p_owner, v_pv2);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch2 create: %', v_r.message; END IF;
    SELECT batch_id INTO v_b2 FROM submission_batch WHERE paper_id = v_paper AND round_no = 2;

    v_r := sp_start_confirmation(v_b2, v_p_owner);
    v_r := sp_record_confirmation(v_b2, v_p_owner, 'CONFIRM', '已按意见补充，确认');
    v_r := sp_record_confirmation(v_b2, v_p_a2,    'CONFIRM', '环境说明完整，确认');
    v_r := sp_record_confirmation(v_b2, v_p_a3,    'CONFIRM', '确认');
    v_r := sp_record_confirmation(v_b2, v_p_a4,    'CONFIRM', '确认');
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch2 confirm: %', v_r.message; END IF;

    v_r := sp_submit_batch(v_b2, v_p_owner);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch2 submit: %', v_r.message; END IF;
    v_r := sp_accept_batch(v_b2, v_p_admin);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch2 accept: %', v_r.message; END IF;
    v_r := sp_review_batch(v_b2, v_p_admin, 'APPROVE', '补充材料完整，审核通过并归档。');
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batch2 approve: %', v_r.message; END IF;

    ---------------------------------------------------------------------------
    -- 12. 分享与授权：受限材料申请 -> 批准 -> 下载；另留一条待审批申请
    ---------------------------------------------------------------------------
    v_r := sp_apply_access(v_acc_user, v_mv_data, '论文复现实验需要原始数据，仅用于方法对比。');
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed access apply: %', v_r.message; END IF;
    SELECT request_id INTO v_req_raw
      FROM access_request
     WHERE requester_account_id = v_acc_user AND material_version_id = v_mv_data
     ORDER BY request_id DESC LIMIT 1;

    v_r := sp_decide_access(v_req_raw, v_p_admin, true, '同意，限 7 天内下载，最多 5 次。', 7, 5);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed access approve: %', v_r.message; END IF;

    -- 模拟一次下载（计数 + 访问日志）
    PERFORM sp_register_download(
        (SELECT grant_id FROM access_grant WHERE request_id = v_req_raw),
        '127.0.0.1');

    -- 待审批申请：图 3 数据来源
    v_r := sp_apply_access(v_acc_user, v_mv_fig, '需要核对图 3 的原始绘图数据。');
    SELECT request_id INTO v_req_fig
      FROM access_request
     WHERE requester_account_id = v_acc_user AND material_version_id = v_mv_fig
     ORDER BY request_id DESC LIMIT 1;

    ---------------------------------------------------------------------------
    -- 13. 对照论文 B：另一研究所的受限项目（用于越权访问/跨所审核测试）
    ---------------------------------------------------------------------------
    INSERT INTO paper (institute_id, owner_person_id, title, abstract, keywords,
                       research_field, venue, submission_status, visibility_level)
    VALUES (v_inst2, v_p_liu,
            '对照项目：跨所受限数据集合',
            '用于验证跨研究所与跨项目访问控制的对照数据。',
            '访问控制;对照', '数据安全', NULL, 'DRAFT', 'RESTRICTED')
    RETURNING paper_id INTO v_paper2;

    INSERT INTO paper_author (paper_id, person_id, author_order, is_corresponding, is_external, affiliation_text)
    VALUES (v_paper2, v_p_liu, 1, true, false, '数据科学研究中心');

    v_f_b_code := pg_temp.mock_file('demo/p2/code.py', 'code.py', 'py', v_p_liu);
    v_f_b_data := pg_temp.mock_file('demo/p2/restricted.csv', 'restricted.csv', 'csv', v_p_liu);
    v_mv_b_code := pg_temp.mock_material(v_paper2, 'CODE', '对照代码', '对照项目代码', 1, v_f_b_code, v_p_liu, '初始版本');
    v_mv_b_data := pg_temp.mock_material(v_paper2, 'RAW_DATA', '受限数据', '未公开的受限数据', 1, v_f_b_data, v_p_liu, '初始版本');

    ---------------------------------------------------------------------------
    -- 14. 演示论文 C：草稿批次，供现场完整演示（发起确认 -> 3/4 -> 提交 ...）
    ---------------------------------------------------------------------------
    INSERT INTO paper (institute_id, owner_person_id, title, abstract, keywords,
                       research_field, venue, submission_status, visibility_level)
    VALUES (v_inst1, v_p_owner,
            '演示论文：可重复实验与版本引用',
            '用于课堂现场演示完整汇交流程的论文。',
            '演示;可重复性;版本引用', '数据管理', 'Demo Conference 2026', 'DRAFT', 'PROJECT')
    RETURNING paper_id INTO v_paper3;

    INSERT INTO paper_author (paper_id, person_id, author_order, is_corresponding, is_external, affiliation_text) VALUES
        (v_paper3, v_p_owner, 1, true,  false, '智能计算研究所'),
        (v_paper3, v_p_a2,    2, false, false, '智能计算研究所'),
        (v_paper3, v_p_a3,    3, false, false, '智能计算研究所'),
        (v_paper3, v_p_a4,    4, false, true,  '华东数据科技有限公司');

    v_f_c_pv   := pg_temp.mock_file('demo/p3/manuscript_v1.pdf', 'manuscript_v1.pdf', 'pdf', v_p_owner);
    v_f_c_code := pg_temp.mock_file('demo/p3/code.py',  'code.py',  'py',   v_p_owner);
    v_f_c_data := pg_temp.mock_file('demo/p3/data.csv', 'data.csv', 'csv',  v_p_owner);
    v_f_c_conf := pg_temp.mock_file('demo/p3/config.yaml', 'config.yaml', 'yaml', v_p_owner);
    v_f_c_log  := pg_temp.mock_file('demo/p3/run.log',  'run.log',  'log',  v_p_owner);
    v_f_c_res  := pg_temp.mock_file('demo/p3/result.json', 'result.json', 'json', v_p_owner);
    v_f_c_notes:= pg_temp.mock_file('demo/p3/env.md',   'env.md',   'md',   v_p_owner);

    INSERT INTO paper_version (paper_id, version_no, stage, file_id, change_note, created_by)
    VALUES (v_paper3, 1, 'SUBMISSION', v_f_c_pv, '演示稿 v1', v_p_owner)
    RETURNING paper_version_id INTO v_pv_c;

    v_mv_c_code := pg_temp.mock_material(v_paper3, 'CODE',     '演示代码', '演示用代码', 1, v_f_c_code, v_p_owner, '初始版本');
    v_mv_c_data := pg_temp.mock_material(v_paper3, 'RAW_DATA', '演示数据', '演示用数据', 1, v_f_c_data, v_p_owner, '初始版本');
    v_mv_c_conf := pg_temp.mock_material(v_paper3, 'CONFIG',   '演示配置', '演示配置',   1, v_f_c_conf, v_p_owner, '初始版本');
    v_mv_c_log  := pg_temp.mock_material(v_paper3, 'LOG',      '演示日志', '演示日志',   1, v_f_c_log,  v_p_owner, '初始版本');
    v_mv_c_res  := pg_temp.mock_material(v_paper3, 'RESULT',   '演示结果', '演示结果',   1, v_f_c_res,  v_p_owner, '初始版本');
    v_mv_c_notes:= pg_temp.mock_material(v_paper3, 'NOTES',    '演示环境', '演示环境说明', 1, v_f_c_notes, v_p_owner, '初始版本');

    INSERT INTO experiment_task (paper_id, title, purpose, scheme, metrics, created_by)
    VALUES (v_paper3, '演示实验：基线复现', '演示实验追溯链路', '固定种子运行一次', '准确率', v_p_owner)
    RETURNING task_id INTO v_task_c;

    INSERT INTO experiment_run (task_id, run_label, code_version_id, data_version_id,
                                config_version_id, log_version_id, parameters,
                                hardware_env, software_env, started_at, ended_at, status, created_by)
    VALUES (v_task_c, 'R1', v_mv_c_code, v_mv_c_data, v_mv_c_conf, v_mv_c_log,
            '{"epochs": 10, "lr": 0.01, "seed": 42}'::jsonb,
            'CPU: 8 cores / 32 GB RAM', 'Python 3.12.4; NumPy 2.1',
            now() - interval '2 days', now() - interval '2 days' + interval '20 minutes',
            'SUCCESS', v_p_owner);

    INSERT INTO experiment_result (run_id, result_version_id, metric_summary, paper_figure_no, conclusion)
    SELECT r.run_id, v_mv_c_res, '准确率 0.901', '图1', '基线可复现'
      FROM experiment_run r WHERE r.task_id = v_task_c AND r.run_label = 'R1';

    v_r := sp_create_batch(v_paper3, v_p_owner, v_pv_c);
    IF NOT v_r.ok THEN RAISE EXCEPTION 'seed batchC create: %', v_r.message; END IF;
    SELECT batch_id INTO v_batch_c FROM submission_batch WHERE paper_id = v_paper3 AND round_no = 1;

    ---------------------------------------------------------------------------
    -- 15. 邮件发件箱：历史邮件标记为已发送
    ---------------------------------------------------------------------------
    UPDATE mail_outbox SET status = 'SENT', sent_at = created_at WHERE created_at < now() - interval '1 minute';

    RAISE NOTICE '演示数据初始化完成：论文 A 已归档（2 轮），论文 C 草稿批次=%', v_batch_c;
END;
$$;

DROP FUNCTION pg_temp.mock_file(text, text, text, bigint);
DROP FUNCTION pg_temp.mock_material(bigint, text, text, text, integer, bigint, bigint, text);
DROP FUNCTION pg_temp.mock_version(bigint, integer, bigint, bigint, text);
