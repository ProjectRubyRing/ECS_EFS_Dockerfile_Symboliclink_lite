# syntax=docker/dockerfile:1
# =============================================================================
# base イメージ
#
# front / back の各 Dockerfile が FROM で参照する共通ベース。
# サービス名・コンポーネント名に依存する処理は一切ここには置かず、
# 全サービス・全コンポーネントで共通の仕込みだけを行う。
#   - EFS マウントポイント (/mnt/logs, /mnt/data) のディレクトリ作成
#   - readonlyRootFilesystem=true 対応のエントリポイントスクリプト配置
#
# ビルド例:
#   docker build -t myapp-base:latest docker/base
# =============================================================================
ARG BASE_IMAGE=registry.access.redhat.com/ubi8/openjdk-11:latest
FROM ${BASE_IMAGE}

USER root

# EFS のマウントポイント。ECS がマウントするため空ディレクトリでよいが、
# イメージ内に存在させておくことでローカル起動時 (-v なし) でも
# シンボリックリンク切れの原因を追いやすくする。
RUN mkdir -p /mnt/logs /mnt/data /webapp /opt/jboss-eap

# EFS 上のディレクトリ整備・タスク ID リンク張り替えを行うエントリポイント
COPY entrypoint.sh /usr/local/bin/efs-entrypoint.sh
RUN chmod 0755 /usr/local/bin/efs-entrypoint.sh \
    # Windows でチェックアウトされた場合の CRLF 混入対策
    && sed -i 's/\r$//' /usr/local/bin/efs-entrypoint.sh

# ここに JBoss EAP 本体の導入やミドルウェア共通設定など、
# front / back 共通のレイヤーを追加する。
# 例)
# COPY jboss-eap-7.4/ /opt/jboss-eap/
# RUN groupadd -r jboss && useradd -r -g jboss -d /opt/jboss-eap jboss \
#     && chown -R jboss:jboss /opt/jboss-eap /webapp

# 実行ユーザーは front / back 側 (または本番のベースイメージ) に合わせて設定する
# USER jboss
