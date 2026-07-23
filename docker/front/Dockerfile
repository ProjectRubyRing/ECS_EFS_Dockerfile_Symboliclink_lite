# syntax=docker/dockerfile:1
# =============================================================================
# フロントコンテナ (webapp9mf02) 用 Dockerfile
#
# readonlyRootFilesystem=true でもタスク起動後にルート FS へ書き込みが
# 発生しないよう、シンボリックリンクはすべて「イメージビルド時」に作成する。
# リンクの実体側 (EFS 上のディレクトリ) はエントリポイントが起動時に
# EFS マウント (/mnt/logs, /mnt/data) 内へ作成する。
#
# 作成するシンボリックリンク:
#   /webapp/webapp9mf02/logs      -> /mnt/logs/<Component_name>/logs/<Service_Name>
#   /webapp/webapp9mf02/pdf       -> /mnt/data/pdf          ※ intra-web のみ
#   /opt/jboss-eap/standalone/log -> /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current
#     (`current` は EFS 上のリンクで、エントリポイントが起動ごとに
#      「起動時刻-ランダム8桁」の実体ディレクトリへ張り替える 2 段リンク構成)
#
# ビルド例 (サービス × コンポーネントごとにイメージを作成する):
#   docker build -t intra-web-front:latest \
#     --build-arg BASE_IMAGE=myapp-base:latest \
#     --build-arg Service_Name=intra-web \
#     --build-arg Component_name=intra-web-front \
#     docker/front
# =============================================================================
ARG BASE_IMAGE=myapp-base:latest
FROM ${BASE_IMAGE}

# タスク定義に設定される値と同じものをビルド引数として受け取る。
# (タスク定義の environment にも同名で設定し、ビルド値と一致させること)
ARG Service_Name
ARG Component_name

# ビルド引数の指定漏れはここで即座に失敗させる
RUN test -n "${Service_Name}"   || { echo "ERROR: --build-arg Service_Name が未指定です"   >&2; exit 1; } \
    && test -n "${Component_name}" || { echo "ERROR: --build-arg Component_name が未指定です" >&2; exit 1; }

# エントリポイントが参照する値を ENV として焼き込む。
# EFS_LOG_DIR をビルド時に確定させておくことで、タスク定義側の環境変数と
# 万一値がずれても「ビルド時に作ったリンク」と「起動時に作る実体」が
# 必ず同じパスを指すようにしている。
ENV Service_Name=${Service_Name} \
    Component_name=${Component_name} \
    COMPONENT_ROLE=front \
    APP_HOME=/webapp/webapp9mf02 \
    EFS_LOG_DIR=/mnt/logs/${Component_name}/logs/${Service_Name}

USER root

# --- ここでアプリケーション本体を配置する ------------------------------------
# COPY --chown=jboss:jboss webapp9mf02/ /webapp/webapp9mf02/
RUN mkdir -p /webapp/webapp9mf02 /opt/jboss-eap/standalone

# --- 1. アプリログ: /webapp/webapp9mf02/logs -> EFS --------------------------
# 既存の logs ディレクトリ(実体)が配置されていても削除してからリンクを作成
RUN rm -rf /webapp/webapp9mf02/logs \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}" /webapp/webapp9mf02/logs

# --- 2. 帳票 pdf: intra-web のフロントコンテナのみ ---------------------------
# 他サービスではリンク自体を作成しない (要件どおり)。
# EFS 側の /mnt/data/pdf の作成はエントリポイントが起動時に行う。
RUN if [ "${Service_Name}" = "intra-web" ] || [ "${Service_Name}" = "intraweb" ]; then \
        rm -rf /webapp/webapp9mf02/pdf; \
        ln -s /mnt/data/pdf /webapp/webapp9mf02/pdf; \
        echo "pdf symlink created for ${Service_Name}"; \
    else \
        echo "pdf symlink skipped for ${Service_Name}"; \
    fi

# --- 3. ミドルウェア(JBoss EAP)ログ ------------------------------------------
# ビルド時に実体の log ディレクトリを削除し、EFS 上の 2 段リンク入口
# (`.../mid/current`) へ向けたリンクに置き換える。
# 起動ごとの実体 (.../mid/<起動時刻-ランダム8桁>) への張り替えはエントリポイントが
# EFS 上 (書き込み可) で行うため、readonlyRootFilesystem=true でも動作する。
RUN rm -rf /opt/jboss-eap/standalone/log \
    && ln -s "/mnt/logs/${Component_name}/logs/${Service_Name}/mid/current" /opt/jboss-eap/standalone/log

# リンクの張り先を確認できるようビルドログへ出力 (ビルド時検証)
RUN ls -l /webapp/webapp9mf02/ /opt/jboss-eap/standalone/ | grep -E ' logs| log| pdf' || true

# 実行ユーザーへ戻す (本番ベースイメージのユーザーに合わせること)
# USER jboss

ENTRYPOINT ["/usr/local/bin/efs-entrypoint.sh"]
# 実際の起動コマンドに合わせて変更する
CMD ["/opt/jboss-eap/bin/standalone.sh", "-b", "0.0.0.0"]
