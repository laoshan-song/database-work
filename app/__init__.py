from flask import Flask

from . import db, security
from .config import Config
from .constants import (
    BATCH_STATUS,
    CONFIRM_COLOR,
    CONFIRM_STATE,
    GRANT_COLOR,
    GRANT_STATUS,
    MATERIAL_COLOR,
    MATERIAL_TYPES,
    PAPER_STAGE,
    PERSON_CATEGORY,
    PERSON_STATUS,
    REVIEW_ACTION,
    ROLE_NAMES,
    STATUS_COLOR,
    SUBMISSION_STATUS,
    VISIBILITY,
    VISIBILITY_COLOR,
)
from .utils import fmt_date, fmt_dt, fmt_size


def create_app(config_object=Config):
    app = Flask(__name__)
    app.config.from_object(config_object)
    app.config["UPLOAD_DIR"].mkdir(parents=True, exist_ok=True)

    db.init_app(app)
    security.init_app(app)

    from .blueprints.access import bp as access_bp
    from .blueprints.admin import bp as admin_bp
    from .blueprints.auth import bp as auth_bp
    from .blueprints.batches import bp as batches_bp
    from .blueprints.experiments import bp as experiments_bp
    from .blueprints.main import bp as main_bp
    from .blueprints.org import bp as org_bp
    from .blueprints.papers import bp as papers_bp

    for bp in (auth_bp, main_bp, org_bp, papers_bp, batches_bp,
               experiments_bp, access_bp, admin_bp):
        app.register_blueprint(bp)

    app.jinja_env.filters["dt"] = fmt_dt
    app.jinja_env.filters["d"] = fmt_date
    app.jinja_env.filters["size"] = fmt_size

    # 常量放入 Jinja 全局命名空间：即使被 import 的宏模板（无 context）也能访问
    app.jinja_env.globals.update(
        BATCH_STATUS=BATCH_STATUS,
        STATUS_COLOR=STATUS_COLOR,
        CONFIRM_STATE=CONFIRM_STATE,
        CONFIRM_COLOR=CONFIRM_COLOR,
        MATERIAL_TYPES=MATERIAL_TYPES,
        MATERIAL_COLOR=MATERIAL_COLOR,
        PAPER_STAGE=PAPER_STAGE,
        SUBMISSION_STATUS=SUBMISSION_STATUS,
        VISIBILITY=VISIBILITY,
        VISIBILITY_COLOR=VISIBILITY_COLOR,
        PERSON_CATEGORY=PERSON_CATEGORY,
        PERSON_STATUS=PERSON_STATUS,
        ROLE_NAMES=ROLE_NAMES,
        GRANT_STATUS=GRANT_STATUS,
        GRANT_COLOR=GRANT_COLOR,
        REVIEW_ACTION=REVIEW_ACTION,
    )

    @app.get("/healthz")
    def healthz():
        from flask import jsonify
        try:
            db.query_one("SELECT 1 AS ok")
        except Exception:  # noqa: BLE001 - 健康检查需要返回 503 触发平台重启
            app.logger.exception("health check failed")
            return jsonify(status="error"), 503
        return jsonify(status="ok")

    @app.errorhandler(403)
    def forbidden(err):
        from flask import render_template
        return render_template("errors/403.html"), 403

    @app.errorhandler(404)
    def not_found(err):
        from flask import render_template
        return render_template("errors/404.html"), 404

    @app.errorhandler(413)
    def too_large(err):
        from flask import flash, redirect, request
        flash("文件超过上传大小限制", "danger")
        return redirect(request.referrer or "/")

    @app.errorhandler(500)
    def server_error(err):
        from flask import render_template
        return render_template("errors/500.html"), 500

    return app
