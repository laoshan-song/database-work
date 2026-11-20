"""pytest 公共夹具。

测试使用独立数据库（默认 srdp_test），不会破坏演示库 srdp。
每次会话开始时执行 db/01~06 重建 schema 并生成演示文件。
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

TEST_DB_URL = os.environ.get(
    "SRDP_TEST_DATABASE_URL", "postgresql://postgres@localhost:5432/srdp_test"
)

from app.pglib import ensure_libpq  # noqa: E402

ensure_libpq()

import psycopg  # noqa: E402
from psycopg.rows import dict_row  # noqa: E402


def make_conninfo(conninfo: str) -> str:
    from psycopg.conninfo import conninfo_to_dict, make_conninfo

    params = conninfo_to_dict(conninfo)
    options = params.get("options", "")
    if "search_path" not in options:
        options = (options + " -c search_path=srdp,public").strip()
    return make_conninfo(**dict(params, options=options))


@pytest.fixture(scope="session", autouse=True)
def _database(tmp_path_factory):
    upload_dir = tmp_path_factory.mktemp("uploads")
    os.environ["SRDP_UPLOAD_DIR"] = str(upload_dir)
    env = dict(os.environ)
    env["SRDP_UPLOAD_DIR"] = str(upload_dir)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "init_db.py"),
            "--database-url",
            TEST_DB_URL,
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"初始化测试库失败：\n{result.stdout}\n{result.stderr}")
    yield


@pytest.fixture(scope="session")
def app(_database):
    os.environ["DATABASE_URL"] = TEST_DB_URL
    os.environ["SECRET_KEY"] = "test-secret"
    from app import create_app

    application = create_app()
    # Config 在模块导入时读取环境变量，这里显式覆盖，确保连接测试库与临时上传目录
    application.config.update(
        TESTING=True,
        WTF_CSRF_ENABLED=False,
        DATABASE_URL=TEST_DB_URL,
        SEARCH_PATH="srdp,public",
        UPLOAD_DIR=Path(os.environ["SRDP_UPLOAD_DIR"]),
    )
    return application


@pytest.fixture()
def client(app):
    with app.test_client() as c:
        yield c


@pytest.fixture()
def login(client):
    def _login(username="admin", password="Demo@2026"):
        # 同一 client 换账号时先退出，否则登录路由会因“已登录”直接跳转
        client.post("/logout")
        resp = client.post(
            "/login",
            data={"username": username, "password": password},
            follow_redirects=False,
        )
        assert resp.status_code == 302, f"登录失败：{username}"
        return client

    return _login


@pytest.fixture(scope="session")
def conninfo():
    return make_conninfo(TEST_DB_URL)


@pytest.fixture()
def db(conninfo):
    with psycopg.connect(conninfo, autocommit=True, row_factory=dict_row) as conn:
        yield conn


@pytest.fixture()
def make_paper(db):
    """创建一篇带 4 位作者、论文版本与必要材料的论文，返回 paper_id。"""
    counter = {"n": 0}

    def _make(visibility="PROJECT", institute_id=1, owner=2, authors=(2, 3, 4, 5)):
        counter["n"] += 1
        title = f"测试论文 {os.getpid()}-{counter['n']}"
        paper_id = db.execute(
            """
            INSERT INTO paper (institute_id, owner_person_id, title, visibility_level)
            VALUES (%s, %s, %s, %s) RETURNING paper_id
            """,
            (institute_id, owner, title, visibility),
        ).fetchone()["paper_id"]

        for order, person_id in enumerate(authors, start=1):
            db.execute(
                """
                INSERT INTO paper_author (paper_id, person_id, author_order,
                                          is_corresponding, is_external)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (paper_id, person_id, order, order == 1, person_id == 5),
            )

        file_id = db.execute("SELECT file_id FROM file_object ORDER BY file_id LIMIT 1").fetchone()["file_id"]
        db.execute(
            """
            INSERT INTO paper_version (paper_id, version_no, stage, file_id, created_by)
            VALUES (%s, 1, 'SUBMISSION', %s, %s)
            """,
            (paper_id, file_id, owner),
        )
        for material_type in ("CODE", "RAW_DATA", "CONFIG", "LOG", "RESULT"):
            material_id = db.execute(
                """
                INSERT INTO material (paper_id, material_type, name)
                VALUES (%s, %s, %s) RETURNING material_id
                """,
                (paper_id, material_type, f"{material_type}-{counter['n']}"),
            ).fetchone()["material_id"]
            db.execute(
                """
                INSERT INTO material_version (material_id, version_no, file_id, change_note, created_by)
                VALUES (%s, 1, %s, '测试数据', %s)
                """,
                (material_id, file_id, owner),
            )
        return paper_id

    return _make


@pytest.fixture()
def draft_batch(db, make_paper):
    """返回 (paper_id, batch_id)，批次处于 DRAFT 状态。"""
    def _make(**kwargs):
        paper_id = make_paper(**kwargs)
        result = db.execute(
            "SELECT * FROM sp_create_batch(%s, %s, NULL)", (paper_id, 2)
        ).fetchone()
        assert result["ok"], result["message"]
        batch_id = db.execute(
            "SELECT batch_id FROM submission_batch WHERE paper_id = %s ORDER BY round_no DESC LIMIT 1",
            (paper_id,),
        ).fetchone()["batch_id"]
        return paper_id, batch_id

    return _make


@pytest.fixture()
def ready_batch(db, draft_batch):
    """返回 (paper_id, batch_id)，批次处于 READY_TO_SUBMIT（4/4 已确认）。"""
    def _make(**kwargs):
        paper_id, batch_id = draft_batch(**kwargs)
        assert db.execute("SELECT * FROM sp_start_confirmation(%s, %s)", (batch_id, 2)).fetchone()["ok"]
        for person_id in (2, 3, 4, 5):
            result = db.execute(
                "SELECT * FROM sp_record_confirmation(%s, %s, 'CONFIRM', 'ok')",
                (batch_id, person_id),
            ).fetchone()
            assert result["ok"], result["message"]
        status = db.execute(
            "SELECT status FROM submission_batch WHERE batch_id = %s", (batch_id,)
        ).fetchone()["status"]
        assert status == "READY_TO_SUBMIT"
        return paper_id, batch_id

    return _make
