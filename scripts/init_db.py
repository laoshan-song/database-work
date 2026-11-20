#!/usr/bin/env python
"""初始化数据库并生成演示文件。

用法：
    python scripts/init_db.py            # 建库 + 执行 db/01~06 + 生成演示文件
    python scripts/init_db.py --no-files # 只建库和执行 SQL
    python scripts/init_db.py --skip-create  # 库已存在，仅重建 schema

说明：
    * 01_schema.sql 会 DROP SCHEMA srdp CASCADE，因此本脚本适合“重置演示环境”；
    * 演示文件内容约定为 b"SRDP-DEMO:" + storage_key，与 06_seed.sql 中
      pgcrypto.digest(...) 计算的 SHA-256 完全一致，可用于校验文件完整性。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.pglib import ensure_libpq  # noqa: E402

ensure_libpq()

import psycopg  # noqa: E402
from dotenv import load_dotenv  # noqa: E402
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="初始化科研论文汇交平台数据库")
    parser.add_argument("--no-files", action="store_true", help="不生成演示文件")
    parser.add_argument("--skip-create", action="store_true", help="不尝试创建数据库")
    parser.add_argument("--database-url", default=None, help="覆盖 DATABASE_URL")
    return parser.parse_args()


def target_conninfo(args) -> str:
    load_dotenv(ROOT / ".env")
    return args.database_url or os.environ.get(
        "DATABASE_URL", "postgresql://postgres@localhost:5432/srdp"
    )


def ensure_database(conninfo: str) -> str:
    params = conninfo_to_dict(conninfo)
    dbname = params.get("dbname") or "srdp"
    admin_params = dict(params, dbname="postgres")
    with psycopg.connect(make_conninfo(**admin_params), autocommit=True) as conn:
        exists = conn.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)
        ).fetchone()
        if not exists:
            conn.execute(f'CREATE DATABASE "{dbname}" ENCODING \'UTF8\' TEMPLATE template0')
            print(f"[db] 已创建数据库 {dbname}")
        else:
            print(f"[db] 数据库 {dbname} 已存在")
    return dbname


def run_sql_files(conninfo: str) -> None:
    db_dir = ROOT / "db"
    with psycopg.connect(conninfo, autocommit=True) as conn:
        for name in SQL_FILES:
            path = db_dir / name
            if not path.is_file():
                raise SystemExit(f"缺少脚本：{path}")
            sql = path.read_text(encoding="utf-8")
            print(f"[sql] 执行 {name} ...", end=" ", flush=True)
            try:
                conn.execute(sql)
            except Exception as exc:  # noqa: BLE001
                print("失败")
                raise SystemExit(f"{name} 执行失败：{exc}") from exc
            print("完成")


def with_search_path(conninfo: str) -> str:
    params = conninfo_to_dict(conninfo)
    options = params.get("options", "")
    if "search_path" not in options:
        options = (options + " -c search_path=srdp,public").strip()
    return make_conninfo(**dict(params, options=options))


def write_demo_files(conninfo: str) -> None:
    upload_dir = Path(os.environ.get("SRDP_UPLOAD_DIR") or (ROOT / "uploads"))
    with psycopg.connect(with_search_path(conninfo)) as conn:
        rows = conn.execute(
            """
            SELECT storage_key, size_bytes, sha256
              FROM file_object
             WHERE storage_key LIKE %s
             ORDER BY file_id
            """,
            ("demo/%",),
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

    print(f"[files] 生成 {written} 个，跳过已存在 {skipped} 个，目录 {upload_dir}")


def main() -> None:
    args = parse_args()
    conninfo = target_conninfo(args)
    if not args.skip_create:
        ensure_database(conninfo)
    run_sql_files(conninfo)
    if not args.no_files:
        write_demo_files(conninfo)
    print("\n初始化完成。启动应用：python run.py")
    print("演示账号：admin / lina / wangqiang / chenjing / zhaolei / sunhao / ops")
    print("统一密码：Demo@2026")


if __name__ == "__main__":
    main()
