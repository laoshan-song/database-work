import hashlib
import os
import uuid
from datetime import datetime
from pathlib import Path

from flask import current_app, flash, request
from werkzeug.utils import secure_filename

from .db import execute


def save_upload(file_storage) -> dict:
    """流式保存上传文件并计算 SHA-256，返回 file_object 所需元数据。"""
    if file_storage is None or not file_storage.filename:
        raise ValueError("请选择要上传的文件")

    original = file_storage.filename
    suffix = Path(original).suffix.lower().lstrip(".")
    safe_base = secure_filename(Path(original).stem)[:60] or "file"
    rel = f"{datetime.now():%Y/%m}/{uuid.uuid4().hex}_{safe_base}"
    if suffix:
        rel += f".{suffix}"

    dest: Path = current_app.config["UPLOAD_DIR"] / rel
    dest.parent.mkdir(parents=True, exist_ok=True)

    digest = hashlib.sha256()
    size = 0
    with dest.open("wb") as out:
        while True:
            chunk = file_storage.stream.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
            out.write(chunk)

    return {
        "storage_key": rel,
        "original_name": original,
        "file_format": suffix or "bin",
        "size_bytes": size,
        "sha256": digest.hexdigest(),
        "abs_path": dest,
    }


def remove_upload(path) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def flash_op(result, success_text="操作成功"):
    """把存储过程返回的 (ok, code, message) 转成页面提示。"""
    if result and result.get("ok"):
        flash(result.get("message") or success_text, "success")
    else:
        flash((result or {}).get("message") or "操作失败", "danger")
    return result


def safe_next(target):
    if target and target.startswith("/") and not target.startswith("//"):
        return target
    return None


def fmt_size(num):
    if num is None:
        return "—"
    num = int(num)
    for unit in ("B", "KB", "MB", "GB"):
        if num < 1024 or unit == "GB":
            return f"{num:.1f} {unit}" if unit != "B" else f"{num} B"
        num /= 1024


def fmt_dt(value, fmt="%Y-%m-%d %H:%M"):
    if not value:
        return "—"
    return value.strftime(fmt)


def fmt_date(value):
    if not value:
        return "—"
    return value.strftime("%Y-%m-%d")


def as_int(value, default=None):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def record_access(account_id, material_version_id, action, detail=None, grant_id=None):
    return execute(
        """
        INSERT INTO access_log (account_id, material_version_id, grant_id, action, detail)
        VALUES (%s, %s, %s, %s, %s)
        """,
        (account_id, material_version_id, grant_id, action, detail),
    )


def client_ip():
    return request.headers.get("X-Forwarded-For", request.remote_addr or "")
