# syntax=docker/dockerfile:1
# =============================================================================
# バックコンテナ (webapp9mb02) 用 Dockerfile
#
# フロント用との差分:
#   - アプリのホームが /webapp/webapp9mf02 ではなく /webapp/webapp9mb02
#   - 帳票 pdf のシンボリックリンクは「作成しない」(intra-web フロント限定要件のため)
#   - COMPONENT_ROLE=back (エントリポイントの pdf 作成判定にも使用)
#
# 作成するシンボリックリンク:
#   /webapp/webapp9mb02/logs      -> /mnt/logs/<Component_name>/logs/<Service_Name>
#   /opt/jboss-eap/standalone/log -> /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current
#
# ビルド例:
#   docker build -t intra-api-back:latest \
#     --build-arg BASE_IMAGE=myapp-base:latest \
#     --build-arg Service_Name=intra-api \
#     --build-arg Component_name=intra-api-back \
#     docker/back
# =============================================================================
ARG BASE_IMAGE=myapp-base:latest
FROM ${BASE_IMAGE}

ARG Service_Name
ARG Component_name

RUN test -n "${Service_Name}"   || { echo "ERROR: --build-arg Service_Name が未指定です"   >&2; exit 1; } \
    && test -n "${Component_name}" || { echo "ERROR: --build-arg Component_name が未指定です" >&2; exit 1; }

ENV Service_Name=${Service_Name} \
    Component_name=${Component_name} \
    COMPONENT_ROLE=back \
    APP_HOME=/webapp/webapp9mb02 \
    EFS_LOG_DIR=/mnt/logs/${Component_name}/logs/${Service_Name}

USER root

# --- ここにアプリケーション本体を配置する ------------------------------------
# COPY --chown=jboss:jboss webapp9mb02/ /webapp/webapp9mb02/
RUN mkdir -p /webapp/webapp9mb02 /opt/jboss-eap/standalone

# --- 1. アプリログ: /webapp/webapp9mb02/logs -> EFS --------------------------
RUN rm -rf /webapp/webapp9mb02/logs \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}" /webapp/webapp9mb02/logs

# --- 2. ミドルウェア(JBoss EAP)ログ ------------------------------------------
# フロントと同様、実体ディレクトリを削除して EFS 上の 2 段リンク入口へ向ける
RUN rm -rf /opt/jboss-eap/standalone/log \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}/mid/current" /opt/jboss-eap/standalone/log

# リンクの張り先を確認できるようビルドログへ出力 (ビルド時検証)
RUN ls -l /webapp/webapp9mb02/ /opt/jboss-eap/standalone/ | grep -E ' logs| log' || true

# 実行ユーザーへ戻す (本番ベースイメージのユーザーに合わせること)
# USER jboss

ENTRYPOINT ["/usr/local/bin/efs-entrypoint.sh"]
CMD ["/opt/jboss-eap/bin/standalone.sh", "-b", "0.0.0.0"]
