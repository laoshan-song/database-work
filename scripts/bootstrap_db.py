#!/usr/bin/env python
"""云端启动引导：空库自动建表与导入演示数据，已有 schema 时只补齐演示文件。

用于 Render / Railway 等平台，在每次进程启动时执行：
    python scripts/bootstrap_db.py

设计要点：
    * 绝不删除已有 schema，避免重启或重新部署清空业务数据；
    * 使用 PostgreSQL advisory lock，多个 worker 同时启动时只初始化一次；
    * 演示文件放在临时磁盘时，重启后会根据 file_object 记录重新生成。
"""
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.pglib import ensure_libpq  # noqa: E402

ensure_libpq()

import psycopg  # noqa: E402
from psycopg.conninfo import conninfo_to_dict, make_conninfo  # noqa: E402

SQL_FILES = [
    "01_schema.sql",
    "02_views.sql",
    "03_functions.sql",
    "04_triggers.sql",
    "05_indexes.sql",
    "06_seed.sql",
]
DEMO_PREFIX = b"SRDP-DEMO:"
LOCK_KEY = 728374


def database_url() -> str:
    return os.environ.get(
        "DATABASE_URL", "postgresql://postgres@localhost:5432/srdp"
    )


def with_search_path(conninfo: str) -> str:
    params = conninfo_to_dict(conninfo)
    options = params.get("options", "")
    if "search_path" not in options:
        options = (options + " -c search_path=srdp,public").strip()
    return make_conninfo(**dict(params, options=options))


def schema_ready(conn: psycopg.Connection) -> bool:
    row = conn.execute(
        "SELECT to_regclass('srdp.submission_batch') IS NOT NULL AS ok"
    ).fetchone()
    return bool(row and row[0])


def run_sql_files(conn: psycopg.Connection) -> None:
    for name in SQL_FILES:
        path = ROOT / "db" / name
        if not path.is_file():
            raise SystemExit(f"缺少数据库脚本：{path}")
        print(f"[bootstrap] 执行 {name} ...", flush=True)
        conn.execute(path.read_text(encoding="utf-8"))


def ensure_demo_files(conn: psycopg.Connection) -> None:
    upload_dir = Path(os.environ.get("SRDP_UPLOAD_DIR") or (ROOT / "uploads"))
    upload_dir.mkdir(parents=True, exist_ok=True)

    rows = conn.execute(
        """
        SELECT storage_key, size_bytes, sha256
          FROM srdp.file_object
         WHERE storage_key LIKE 'demo/%'
         ORDER BY file_id
        """
    ).fetchall()

    written = skipped = 0
    for storage_key, size_bytes, sha256 in rows:
        path = upload_dir / storage_key
        content = DEMO_PREFIX + storage_key.encode("utf-8")
        if path.exists() and path.stat().st_size == size_bytes:
            skipped += 1
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        actual = hashlib.sha256(content).hexdigest()
        if len(content) != size_bytes or actual != sha256:
            raise SystemExit(
                f"演示文件校验失败：{storage_key} "
                f"(size {len(content)}/{size_bytes}, sha256 {actual[:12]}/{sha256[:12]})"
            )
        written += 1

    print(f"[bootstrap] 演示文件：新生成 {written}，已存在 {skipped}，目录 {upload_dir}")


def main() -> None:
    url = with_search_path(database_url())
    with psycopg.connect(url, autocommit=True) as conn:
        conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
        try:
            if schema_ready(conn):
                print("[bootstrap] 数据库已初始化，跳过建表")
            else:
                print("[bootstrap] 检测到空数据库，开始初始化")
                run_sql_files(conn)
            ensure_demo_files(conn)
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_KEY,))
    print("[bootstrap] 完成")


if __name__ == "__main__":
    main()
