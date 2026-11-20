"""并发测试：行锁 + 唯一索引 + 存储过程的原子校验。

每个线程使用独立连接，通过 Barrier 同时发起请求，验证：
1. 同一批次并发提交只有一次成功；
2. 同一论文并发创建批次只有一个成功；
3. 下载次数上限在并发下不会被突破。
"""
from __future__ import annotations

import threading

import psycopg
import pytest
from psycopg.rows import dict_row


def run_parallel(conninfo, work, workers):
    """所有线程各建连接，在 Barrier 处对齐后并发执行 work(conn)。"""
    barrier = threading.Barrier(workers)
    results = [None] * workers
    errors = [None] * workers

    def worker(index):
        try:
            with psycopg.connect(conninfo, autocommit=True, row_factory=dict_row) as conn:
                barrier.wait(timeout=30)
                results[index] = work(conn)
        except Exception as exc:  # noqa: BLE001 - 测试中记录后统一断言
            errors[index] = exc

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)
    assert not any(t.is_alive() for t in threads), "并发线程未在超时前结束"
    assert not any(errors), f"并发执行出现异常：{[e for e in errors if e]}"
    return results


def test_concurrent_submit_only_one_succeeds(conninfo, ready_batch):
    _, batch_id = ready_batch()

    def call(conn):
        return conn.execute(
            "SELECT * FROM sp_submit_batch(%s, %s)", (batch_id, 2)
        ).fetchone()

    results = run_parallel(conninfo, call, 6)
    successes = [r for r in results if r["ok"]]
    assert len(successes) == 1, results
    assert {r["code"] for r in results if not r["ok"]} <= {"BAD_STATE"}


def test_concurrent_create_batch_only_one_succeeds(conninfo, make_paper):
    paper_id = make_paper()

    def call(conn):
        return conn.execute(
            "SELECT * FROM sp_create_batch(%s, %s, NULL)", (paper_id, 2)
        ).fetchone()

    results = run_parallel(conninfo, call, 6)
    successes = [r for r in results if r["ok"]]
    assert len(successes) == 1, results
    assert {r["code"] for r in results if not r["ok"]} == {"OPEN_BATCH_EXISTS"}

    # 只落下一个批次
    with psycopg.connect(conninfo, autocommit=True, row_factory=dict_row) as conn:
        count = conn.execute(
            "SELECT count(*) AS n FROM submission_batch WHERE paper_id = %s",
            (paper_id,),
        ).fetchone()["n"]
    assert count == 1


def test_download_limit_not_exceeded_under_concurrency(conninfo, make_paper):
    paper_id = make_paper()
    with psycopg.connect(conninfo, autocommit=True, row_factory=dict_row) as conn:
        mv = conn.execute(
            """
            SELECT mv.material_version_id
              FROM material_version mv
              JOIN material m ON m.material_id = mv.material_id
             WHERE m.paper_id = %s ORDER BY mv.version_no DESC LIMIT 1
            """,
            (paper_id,),
        ).fetchone()["material_version_id"]
        account = conn.execute(
            "SELECT account_id FROM account WHERE username = 'sunhao'"
        ).fetchone()["account_id"]
        request_id = conn.execute(
            """
            INSERT INTO access_request
                (requester_account_id, material_version_id, reason, status, decided_by, decided_at)
            VALUES (%s, %s, '并发下载测试', 'APPROVED', 1, now())
            RETURNING request_id
            """,
            (account, mv),
        ).fetchone()["request_id"]
        grant_id = conn.execute(
            """
            INSERT INTO access_grant
                (request_id, account_id, material_version_id, valid_to, max_downloads)
            VALUES (%s, %s, %s, now() + interval '1 day', 3)
            RETURNING grant_id
            """,
            (request_id, account, mv),
        ).fetchone()["grant_id"]

    def call(conn):
        return conn.execute(
            "SELECT * FROM sp_register_download(%s, '10.0.0.9')", (grant_id,)
        ).fetchone()

    results = run_parallel(conninfo, call, 8)
    successes = [r for r in results if r["ok"]]
    assert len(successes) == 3, results
    assert {r["code"] for r in results if not r["ok"]} == {"EXHAUSTED"}

    with psycopg.connect(conninfo, autocommit=True, row_factory=dict_row) as conn:
        grant = conn.execute(
            "SELECT download_count FROM access_grant WHERE grant_id = %s", (grant_id,)
        ).fetchone()
        logs = conn.execute(
            "SELECT count(*) AS n FROM access_log WHERE grant_id = %s AND action = 'DOWNLOAD'",
            (grant_id,),
        ).fetchone()["n"]
    assert grant["download_count"] == 3
    assert logs == 3
