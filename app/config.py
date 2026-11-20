import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "srdp-dev-secret-change-me")
    DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres@localhost:5432/srdp")
    SEARCH_PATH = os.environ.get("SRDP_SEARCH_PATH", "srdp,public")
    UPLOAD_DIR = Path(os.environ.get("SRDP_UPLOAD_DIR", BASE_DIR / "uploads"))
    MAX_CONTENT_LENGTH = int(os.environ.get("SRDP_MAX_UPLOAD_MB", "200")) * 1024 * 1024
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    PERMANENT_SESSION_LIFETIME = 8 * 60 * 60
