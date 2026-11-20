#!/usr/bin/env python
"""生成性能测试库 srdp_bench（结构与 srdp 相同，追加规模化数据）。

用途：
    * 演示索引命中与执行计划（配合 db/08_explain.sql）
    * 观察数据量增长后优化器的计划选择

用法：
    python scripts/gen_bench.py                 # 重建 srdp_bench 并灌入压测数据
    python scripts/gen_bench.py --no-init       # 跳过建库，仅追加数据
    python scripts/gen_bench.py --database-url postgresql://postgres@localhost:5432/srdp_bench

注意：脚本会先执行 db/01~06，DROP SCHEMA srdp CASCADE，请勿指向演示库。
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.pglib import ensure_libpq  # noqa: E402

ensure_libpq()

import psycopg  # noqa: E402
from psycopg.conninfo import conninfo_to_dict, make_conninfo  # noqa: E402

DEFAULT_URL = os.environ.get(
    "SRDP_BENCH_DATABASE_URL", "postgresql://postgres@localhost:5432/srdp_bench"
)
EXTRA_PERSONS = 400
PAPERS = 3000
AUDIT_ROWS = 200_000

BULK_SQL = f"""
-- 1. 规模人员
INSERT INTO person (employee_no, name, email, person_category, home_institute_id, join_date)
SELECT 'B' || lpad(g::text, 5, '0'),
       '压测用户' || g,
       'bench' || g || '@example.org',
       'RESEARCHER',
       (g % 2) + 1,
       DATE '2020-01-01' + (g % 900)
  FROM generate_series(1, {EXTRA_PERSONS}) g;

-- 2. 论文（每篇 4 位作者：负责人 + 3 位压测人员）
INSERT INTO paper (institute_id, owner_person_id, title, abstract, keywords,
                   research_field, venue, submission_status, visibility_level, created_at)
SELECT (g % 2) + 1,
       p.person_id,
       '压测论文 ' || lpad(g::text, 5, '0'),
       '用于执行计划与索引验证的规模化论文数据。',
       '压测 索引 执行计划',
       '数据管理',
       'Bench Conference 2026',
       'SUBMITTED',
       CASE WHEN g % 7 = 0 THEN 'PUBLIC'
            WHEN g % 7 = 1 THEN 'INSTITUTE'
            ELSE 'PROJECT' END,
       now() - (g || ' minutes')::interval
  FROM generate_series(1, {PAPERS}) g
  JOIN person p ON p.employee_no = 'B' || lpad(((g % {EXTRA_PERSONS}) + 1)::text, 5, '0');

INSERT INTO paper_author (paper_id, person_id, author_order, is_corresponding, is_external)
SELECT p.paper_id, p.owner_person_id, 1, true, false
  FROM paper p
 WHERE p.title LIKE '压测论文 %';

INSERT INTO paper_author (paper_id, person_id, author_order, is_corresponding, is_external)
SELECT p.paper_id, q.person_id, q.rn + 1, false, false
  FROM paper p
  JOIN LATERAL (
        SELECT person_id, row_number() OVER () AS rn
          FROM person
         WHERE employee_no LIKE 'B%'
           AND person_id <> p.owner_person_id
         ORDER BY (p.paper_id * 7 + person_id) % {EXTRA_PERSONS}
         LIMIT 3
       ) q ON true
 WHERE p.title LIKE '压测论文 %';

-- 3. 每篇论文一份论文稿版本
INSERT INTO paper_version (paper_id, version_no, stage, file_id, change_note, created_by)
SELECT p.paper_id, 1, 'SUBMISSION', f.file_id, '压测版本', p.owner_person_id
  FROM paper p
 CROSS JOIN (SELECT file_id FROM file_object ORDER BY file_id LIMIT 1) f
 WHERE p.title LIKE '压测论文 %';

-- 4. 每篇论文 8 类材料，各 1 个版本（触发器计算 SHA-256）
INSERT INTO material (paper_id, material_type, name, description)
SELECT p.paper_id, t.mt, t.mt || '-' || p.paper_id, '压测材料'
  FROM paper p
 CROSS JOIN unnest(ARRAY['CODE','RAW_DATA','CONFIG','LOG','RESULT','FIGURE','NOTES','DATA_DICT']) AS t(mt)
 WHERE p.title LIKE '压测论文 %';

INSERT INTO material_version (material_id, version_no, file_id, change_note, created_by)
SELECT m.material_id, 1, f.file_id, '压测初始版本', p.owner_person_id
  FROM material m
  JOIN paper p ON p.paper_id = m.paper_id
 CROSS JOIN (SELECT file_id FROM file_object ORDER BY file_id LIMIT 1) f
 WHERE p.title LIKE '压测论文 %';

-- 5. 每篇论文一个批次（草稿），再按比例推进到不同状态
INSERT INTO submission_batch (
    paper_id, round_no, institute_id, initiated_by, status, paper_version_id,
    title_snapshot, abstract_snapshot, keywords_snapshot, research_field_snapshot,
    venue_snapshot, doi_snapshot, visibility_snapshot, owner_snapshot, author_count, created_at)
SELECT p.paper_id, 1, p.institute_id, p.owner_person_id, 'DRAFT', pv.paper_version_id,
       p.title, p.abstract, p.keywords, p.research_field, p.venue, p.doi,
       p.visibility_level, p.owner_person_id, 4, p.created_at
  FROM paper p
  JOIN paper_version pv ON pv.paper_id = p.paper_id
 WHERE p.title LIKE '压测论文 %';

INSERT INTO batch_author (batch_id, person_id, author_order, is_corresponding,
                          is_external, is_owner, name_snapshot, affiliation_snapshot)
SELECT b.batch_id, pa.person_id, pa.author_order, pa.is_corresponding, pa.is_external,
       pa.person_id = b.owner_snapshot, per.name, i.name
  FROM submission_batch b
  JOIN paper_author pa ON pa.paper_id = b.paper_id
  JOIN person per ON per.person_id = pa.person_id
  LEFT JOIN institute i ON i.institute_id = per.home_institute_id
 WHERE b.title_snapshot LIKE '压测论文 %';

INSERT INTO batch_material (batch_id, material_version_id, material_type,
                            material_name_snapshot, version_no_snapshot, sha256_snapshot)
SELECT b.batch_id, mv.material_version_id, m.material_type, m.name, mv.version_no, mv.sha256
  FROM submission_batch b
  JOIN material m ON m.paper_id = b.paper_id
  JOIN material_version mv ON mv.material_id = m.material_id
 WHERE b.title_snapshot LIKE '压测论文 %';

-- 状态推进必须走合法路径（触发器校验状态机）
UPDATE submission_batch
   SET status = 'PENDING_AUTHORS', frozen_at = created_at + interval '1 hour'
 WHERE title_snapshot LIKE '压测论文 %' AND paper_id % 5 <> 4;

UPDATE submission_batch
   SET status = 'READY_TO_SUBMIT'
 WHERE title_snapshot LIKE '压测论文 %' AND paper_id % 5 = 0;

UPDATE submission_batch
   SET status = 'PENDING_ADMIN', submitted_at = frozen_at + interval '1 hour'
 WHERE title_snapshot LIKE '压测论文 %' AND paper_id % 5 = 0;

UPDATE submission_batch
   SET status = 'UNDER_REVIEW'
 WHERE title_snapshot LIKE '压测论文 %' AND paper_id % 5 = 0;

UPDATE submission_batch
   SET status = 'ARCHIVED', ended_at = submitted_at + interval '1 hour', ended_reason = 'APPROVE'
 WHERE title_snapshot LIKE '压测论文 %' AND paper_id % 5 = 0;

-- 6. 确认记录：PENDING_AUTHORS 批次中前两位作者已确认
INSERT INTO confirmation (batch_id, person_id, action, comment, is_current, created_by)
SELECT ba.batch_id, ba.person_id, 'CONFIRM', 'bench',
       ba.author_order <= 2, ba.person_id
  FROM batch_author ba
  JOIN submission_batch b ON b.batch_id = ba.batch_id
 WHERE b.status = 'PENDING_AUTHORS';

-- 7. 实验任务 / 运行 / 结果
INSERT INTO experiment_task (paper_id, title, purpose, scheme, metrics, created_by)
SELECT p.paper_id, '压测实验-' || p.paper_id, '规模数据', '批量生成', '耗时', p.owner_person_id
  FROM paper p
 WHERE p.title LIKE '压测论文 %';

INSERT INTO experiment_run (task_id, run_label, code_version_id, data_version_id,
                            config_version_id, log_version_id, parameters,
                            hardware_env, software_env, started_at, ended_at, status, created_by)
SELECT t.task_id, 'R' || k, c.mv, d.mv, cf.mv, lg.mv,
       jsonb_build_object('epochs', 10, 'seed', k),
       'CPU 8C/32G', 'Python 3.12', now() - interval '1 day', now() - interval '1 day' + interval '10 minutes',
       'SUCCESS', p.owner_person_id
  FROM experiment_task t
  JOIN paper p ON p.paper_id = t.paper_id
 CROSS JOIN generate_series(1, 3) k
  JOIN LATERAL (SELECT mv.material_version_id AS mv FROM material m
                  JOIN material_version mv ON mv.material_id = m.material_id
                 WHERE m.paper_id = p.paper_id AND m.material_type = 'CODE' LIMIT 1) c ON true
  JOIN LATERAL (SELECT mv.material_version_id AS mv FROM material m
                  JOIN material_version mv ON mv.material_id = m.material_id
                 WHERE m.paper_id = p.paper_id AND m.material_type = 'RAW_DATA' LIMIT 1) d ON true
  JOIN LATERAL (SELECT mv.material_version_id AS mv FROM material m
                  JOIN material_version mv ON mv.material_id = m.material_id
                 WHERE m.paper_id = p.paper_id AND m.material_type = 'CONFIG' LIMIT 1) cf ON true
  JOIN LATERAL (SELECT mv.material_version_id AS mv FROM material m
                  JOIN material_version mv ON mv.material_id = m.material_id
                 WHERE m.paper_id = p.paper_id AND m.material_type = 'LOG' LIMIT 1) lg ON true
 WHERE t.title LIKE '压测实验-%';

INSERT INTO experiment_result (run_id, result_version_id, metric_summary, paper_figure_no, conclusion)
SELECT r.run_id, res.mv, 'accuracy 0.9', '图' || (r.run_id % 10), '压测结果'
  FROM experiment_run r
  JOIN experiment_task t ON t.task_id = r.task_id
  JOIN paper p ON p.paper_id = t.paper_id
  JOIN LATERAL (SELECT mv.material_version_id AS mv FROM material m
                  JOIN material_version mv ON mv.material_id = m.material_id
                 WHERE m.paper_id = p.paper_id AND m.material_type = 'RESULT' LIMIT 1) res ON true
 WHERE t.title LIKE '压测实验-%';

-- 8. 审计日志（批量灌入，触发器保证只读）
INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary, created_at)
SELECT 1,
       (ARRAY['submission_batch','material_version','confirmation','access_request','access_grant'])[1 + g % 5],
       (g % 5000)::text,
       'BENCH',
       jsonb_build_object('n', g),
       now() - (g || ' minutes')::interval
  FROM generate_series(1, {AUDIT_ROWS}) g;

-- 9. 通知（未读部分索引）
INSERT INTO notification (account_id, category, title, body, link_url, created_at)
SELECT a.account_id, 'BENCH', '压测通知 ' || g, '规模数据', '/', now() - (g || ' minutes')::interval
  FROM generate_series(1, 5000) g
  JOIN LATERAL (SELECT account_id FROM account ORDER BY account_id LIMIT 1) a ON true;
"""


def parse_args():
    parser = argparse.ArgumentParser(description="生成性能测试库 srdp_bench")
    parser.add_argument("--database-url", default=DEFAULT_URL)
    parser.add_argument("--no-init", action="store_true", help="跳过 db/01~06")
    return parser.parse_args()


def with_search_path(conninfo: str) -> str:
    params = conninfo_to_dict(conninfo)
    options = params.get("options", "")
    if "search_path" not in options:
        options = (options + " -c search_path=srdp,public").strip()
    return make_conninfo(**dict(params, options=options))


def main():
    args = parse_args()
    if not args.no_init:
        cmd = [
            sys.executable,
            str(ROOT / "scripts" / "init_db.py"),
            "--database-url",
            args.database_url,
            "--no-files",
        ]
        print("[bench] 初始化结构与演示数据 ...")
        result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        if result.returncode != 0:
            raise SystemExit(f"初始化失败：\n{result.stdout}\n{result.stderr}")
        print(result.stdout.strip().splitlines()[-1])

    started = time.perf_counter()
    with psycopg.connect(with_search_path(args.database_url), autocommit=True) as conn:
        for statement in [s.strip() for s in BULK_SQL.split(";") if s.strip()]:
            t0 = time.perf_counter()
            conn.execute(statement + ";")
            label = " ".join(statement.split()[:6])
            print(f"[bench] {time.perf_counter() - t0:6.2f}s  {label} ...")

        conn.execute("ANALYZE;")
        counts = conn.execute(
            """
            SELECT (SELECT count(*) FROM paper)      AS papers,
                   (SELECT count(*) FROM material_version) AS material_versions,
                   (SELECT count(*) FROM submission_batch) AS batches,
                   (SELECT count(*) FROM experiment_result) AS results,
                   (SELECT count(*) FROM audit_log)  AS audits
            """
        ).fetchone()
    print(f"[bench] 完成，用时 {time.perf_counter() - started:.1f}s")
    print(f"[bench] 论文 {counts[0]}，材料版本 {counts[1]}，批次 {counts[2]}，"
          f"实验结果 {counts[3]}，审计日志 {counts[4]}")
    print("[bench] 运行执行计划：psql -d srdp_bench -f db/08_explain.sql")


if __name__ == "__main__":
    main()
