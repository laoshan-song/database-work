"""定位本机 libpq（Windows 下 psycopg 需要）。

psycopg 3 在 Windows 上要么使用自带的 psycopg_binary，要么通过 ctypes 加载
PostgreSQL 安装目录中的 libpq.dll。某些环境下 wheel 内的 DLL 依赖不完整，
此时把 PostgreSQL 的 bin 目录加入 DLL 搜索路径即可正常导入。

其他平台不做任何处理。
"""
import os
import sys
from pathlib import Path


def _candidate_dirs():
    explicit = os.environ.get("SRDP_PG_BIN")
    if explicit:
        yield Path(explicit)
    if sys.platform != "win32":
        return
    for env_name in ("ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"):
        root = os.environ.get(env_name)
        if not root:
            continue
        base = Path(root) / "PostgreSQL"
        if not base.is_dir():
            continue
        # 版本号目录倒序，优先使用较新的版本
        for child in sorted((p for p in base.iterdir() if p.is_dir()), reverse=True):
            yield child / "bin"


def ensure_libpq():
    """把含 libpq.dll 的目录加入 DLL 搜索路径，返回命中的目录。"""
    if sys.platform != "win32":
        return None
    for directory in _candidate_dirs():
        try:
            if not (directory / "libpq.dll").is_file():
                continue
        except OSError:
            continue
        try:
            os.add_dll_directory(str(directory))
        except (AttributeError, OSError):
            pass
        current = os.environ.get("PATH", "")
        if str(directory) not in current.split(os.pathsep):
            os.environ["PATH"] = f"{directory}{os.pathsep}{current}"
        return str(directory)
    return None
