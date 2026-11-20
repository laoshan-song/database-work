"""数据库访问：每个请求一个连接，autocommit=True，写操作显式开事务。"""
from contextlib import contextmanager

from .pglib import ensure_libpq

ensure_libpq()

import psycopg  # noqa: E402
from flask import current_app, g  # noqa: E402
from psycopg.rows import dict_row  # noqa: E402


def get_db() -> psycopg.Connection:
    if "db" not in g:
        g.db = psycopg.connect(
            current_app.config["DATABASE_URL"],
            row_factory=dict_row,
            autocommit=True,
            options=f"-c search_path={current_app.config['SEARCH_PATH']}",
        )
    return g.db


def close_db(exc=None):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def query(sql: str, params=None):
    with get_db().cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def query_one(sql: str, params=None):
    with get_db().cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def scalar(sql: str, params=None):
    row = query_one(sql, params)
    if not row:
        return None
    return next(iter(row.values()))


def execute(sql: str, params=None) -> int:
    with get_db().cursor() as cur:
        cur.execute(sql, params)
        return cur.rowcount


@contextmanager
def transaction():
    """多语句写入的原子事务；异常自动回滚。"""
    conn = get_db()
    with conn.transaction():
        with conn.cursor() as cur:
            yield cur


def call_proc(name: str, *args, cur=None):
    """调用返回 op_result 的存储过程/函数。"""
    sql = f"SELECT * FROM {name}({','.join(['%s'] * len(args))})"
    if cur is not None:
        cur.execute(sql, args)
        return cur.fetchone()
    with get_db().cursor() as c:
        c.execute(sql, args)
        return c.fetchone()


def init_app(app):
    app.teardown_appcontext(close_db)
