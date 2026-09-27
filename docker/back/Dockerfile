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
#   /opt/jboss-eap/standalone/log -> tmp/jboss-log-target
#     相対リンク。実体は起動時に、タスクローカルな standalone/tmp 上の
#     jboss-log-target から EFS の実ディレクトリへ張る。
#     共有の mid/current は案内札であり、server.log を開く経路ではない。
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
# フロントと同様、実体ディレクトリを削除してタスクローカルな
# tmp/jboss-log-target への相対リンクに置き換える。
# 共有の mid/current は開く経路にしない (日付ローテーションの rename が
# 他タスクの server.log を前日付ファイルへ付け替えるのを防ぐ)。
RUN rm -rf /opt/jboss-eap/standalone/log \
    && ln -s tmp/jboss-log-target /opt/jboss-eap/standalone/log

# リンクの張り先を確認できるようビルドログへ出力 (ビルド時検証)
RUN ls -l /webapp/webapp9mb02/ /opt/jboss-eap/standalone/ | grep -E ' logs| log' || true

# 実行ユーザーへ戻す (本番ベースイメージのユーザーに合わせること)
# USER jboss

ENTRYPOINT ["/usr/local/bin/efs-entrypoint.sh"]
CMD ["/opt/jboss-eap/bin/standalone.sh", "-b", "0.0.0.0"]
