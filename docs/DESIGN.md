# ECS + EFS シンボリックリンク設計解説

対象: ECS クラスタ上の 4 サービス (`interapi` / `intra-api` / `intra-web(intraweb)` / `sfapi`)。
各タスクはフロントコンテナ・バックコンテナ・サイドカーコンテナで構成され、
フロント/バックは EFS を `/mnt/logs` (アプリログ・ミドルウェアログ) と
`/mnt/data` (帳票ファイル) にマウントする。
タスク定義は `readonlyRootFilesystem=true` で運用する。

---

## 1. 全体像 (リンク構成図)

```
【ルートFS = イメージビルド時に作成 (起動後は read-only)】

  フロントコンテナ
    /webapp/webapp9mf02/logs ──────────────► /mnt/logs/<Component_name>/logs/<Service_Name>
    /webapp/webapp9mf02/pdf  ──────────────► /mnt/data/pdf          ※ intra-web のみ作成
    /opt/jboss-eap/standalone/log ─────────► /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current

  バックコンテナ
    /webapp/webapp9mb02/logs ──────────────► /mnt/logs/<Component_name>/logs/<Service_Name>
    /opt/jboss-eap/standalone/log ─────────► /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current

【EFS 上 = エントリポイントがタスク起動のたびに作成 (常に書き込み可)】

    /mnt/logs/<Component_name>/logs/<Service_Name>/            … アプリログ実体
    /mnt/logs/<Component_name>/logs/<Service_Name>/mid/
        ├── current ──► <ECSタスクID>      (起動ごとに ln -sfn で張り替え)
        ├── <ECSタスクID-1>/               … 前々回タスクの JBoss ログ (残存)
        ├── <ECSタスクID-2>/               … 前回タスクの JBoss ログ (残存)
        └── <ECSタスクID-3>/               … 今回タスクの JBoss ログ ◄─ current
    /mnt/data/pdf/                          … intra-web フロントの起動時に無ければ作成
```

## 2. なぜこの構成なのか — readonlyRootFilesystem=true との両立

`readonlyRootFilesystem=true` のコンテナは、**起動後にルートファイルシステムへ
一切書き込めない**。したがって:

- ルート FS 側に置くもの (シンボリックリンク 3 種、既存 log ディレクトリの削除)
  は **必ずイメージビルド時 (Dockerfile の RUN)** に済ませる。
- 起動後に書き込みが必要なもの (ログ実体ディレクトリ、タスクごとのディレクトリ、
  `current` リンクの張り替え、`/mnt/data/pdf` の作成) は **すべて EFS マウント上**
  で行う。EFS ボリュームは readonlyRootFilesystem の制約対象外であり、
  タスク定義側で read-only 指定をしない限り書き込み可能。

この分担により、起動後のルート FS 書き込みはゼロになる。

## 3. JBoss EAP ログの「タスクごとの一意性」— 2 段リンク方式 (採用案)

### 課題

要件は `/opt/jboss-eap/standalone/log` を
`/mnt/logs/<コンテナ名>/logs/<サービス名>/mid/<ECSタスクID>` に向けること。
しかし **ECS タスク ID はイメージビルド時には存在しない**。
タスク ID はタスクが RunTask/サービススケジューラで起動された瞬間に採番される値で、
同一イメージから何百ものタスクが起動されるため、ビルド時に焼き込むことは
原理的に不可能である。一方、リンク自体はビルド時に作るしかない (2 章の制約)。

### 解決: リンクを 2 段に分ける

1. **ビルド時 (ルート FS 側)**:
   `/opt/jboss-eap/standalone/log → /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current`
   という「固定の」リンクを作成する。タスク ID を含まないためビルド時に確定できる。
2. **起動時 (EFS 側)**: エントリポイント `efs-entrypoint.sh` が
   - ECS メタデータエンドポイント v4 (`${ECS_CONTAINER_METADATA_URI_V4}/task`) から
     `TaskARN` を取得し、末尾のタスク ID を切り出す
   - `mid/<タスクID>` ディレクトリを作成する
   - EFS 上のリンク `mid/current` を `ln -sfn <タスクID> mid/current` で張り替える

JBoss がログを書くときのパス解決は
`/opt/jboss-eap/standalone/log` → `mid/current` → `mid/<今回のタスクID>`
と 2 段で辿られ、**タスクが切り替わるたびに新しいディレクトリへ書き込まれる**。
過去タスクのディレクトリは EFS 上にそのまま残るため、
前のタスクのログとの一意性が維持される。

### タスク ID が取得できない場合の代替ディレクトリ名

メタデータエンドポイントが無効・応答しない環境 (ローカル docker run 等) では、
`起動時刻(YYYYMMDDhhmmss)-ランダム8桁` (例: `20260721103045-3fa1b2c4`) を
ディレクトリ名にする。起動のたびに必ず異なる名前になるため、
タスク ID と同等の「タスク切替ごとの一意性」を満たす。

## 4. Service_Name / Component_name の渡し方 (検討と採用)

タスク定義には環境変数 `Service_Name`(サービス名)・`Component_name`(コンテナ名)
が設定されるが、これは**タスク起動後にしか存在しない**。シンボリックリンクは
ビルド時に作る必要があるため、値の入手経路を次のとおり整理した。

| # | 経路 | 利用可能タイミング | 採否 |
|---|------|-------------------|------|
| 1 | `docker build --build-arg Service_Name=… --build-arg Component_name=…` | ビルド時 | **採用 (リンク作成用)** |
| 2 | タスク定義の environment (`Service_Name` / `Component_name`) | 起動後 | 採用 (エントリポイントの補助・突合せ用) |
| 3 | ECS メタデータエンドポイント v4 の `ServiceName` / コンテナ `Name` | 起動後 | 参考 (ビルド時に使えないため主経路にしない) |
| 4 | SSM パラメータストア / Secrets Manager | ビルド時・起動後 | 不採用 (build-arg で足りる。外部依存が増えるだけ) |

- **ビルド時**は CI (CodeBuild / GitHub Actions 等) がサービスごとに
  `--build-arg` を渡す。Dockerfile は値の未指定を `RUN test -n` で即エラーにする。
- 受け取った値は `ENV Service_Name` / `ENV Component_name` としてイメージに焼き込み、
  さらに **リンク先パス全体を `ENV EFS_LOG_DIR` として確定**させる。
  エントリポイントはこの `EFS_LOG_DIR` だけを見てディレクトリを作るため、
  タスク定義側の環境変数とビルド引数の値が万一食い違っても、
  「ビルド時に作ったリンク」と「起動時に作る実体」が必ず一致する。
- **起動時**のメタデータエンドポイント v4 は、タスクメタデータに `ServiceName`、
  コンテナメタデータに `Name` を含むため、環境変数を使わずに同じ情報を
  取得することも可能である。ただしこれはあくまで起動後の話であり、
  ビルド時のリンク作成には使えない。本実装ではタスク ID の取得のみに
  メタデータエンドポイントを使用している。

**帰結**: イメージは「サービス × コンポーネント」ごとに個別ビルドとなる
(4 サービス × front/back = 最大 8 イメージ)。これはリンク先パスに
サービス名を焼き込むという要件の必然的な帰結である。
単一イメージで済ませたい場合の代替案は `REJECTED_ALTERNATIVES.md` の案 E を参照。

## 5. ビルドとデプロイの流れ

```bash
# 1. base (全サービス共通・1 回だけ)
docker build -t myapp-base:latest docker/base

# 2. front / back (サービスごとに build-arg を変えてビルド)
docker build -t interapi-front:latest \
  --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=interapi \
  --build-arg Component_name=interapi-front \
  docker/front

docker build -t interapi-back:latest \
  --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=interapi \
  --build-arg Component_name=interapi-back \
  docker/back
# … intra-api / intra-web / sfapi も同様
```

タスク定義側の要点:

```jsonc
{
  "containerDefinitions": [{
    "name": "interapi-front",                       // = Component_name
    "readonlyRootFilesystem": true,
    "environment": [
      { "name": "Service_Name",   "value": "interapi" },
      { "name": "Component_name", "value": "interapi-front" }
    ],
    "mountPoints": [
      { "sourceVolume": "logs", "containerPath": "/mnt/logs" },
      { "sourceVolume": "data", "containerPath": "/mnt/data" }
    ]
  }],
  "volumes": [
    { "name": "logs", "efsVolumeConfiguration": { "fileSystemId": "fs-xxxx", "rootDirectory": "/logs-root" } },
    { "name": "data", "efsVolumeConfiguration": { "fileSystemId": "fs-xxxx", "rootDirectory": "/data-root" } }
  ]
}
```

## 6. 運用上の注意点

1. **同一サービスの並行タスク (desiredCount > 1) と `current` リンク**
   同じサービス・同じコンポーネントのタスクが複数同時に走ると、後から起動した
   タスクが `current` を自分の ID へ張り替える。先行タスクの JBoss は
   open 済みファイルハンドルには書き続けられるが、ローテーションで新規作成
   されるファイルは後発タスクのディレクトリ側へ入り、混在が起きうる。
   desiredCount=1 (ローリング時の一時 2 タスクは許容) なら実害はほぼ無いが、
   常時複数タスクで厳密な分離が必要なら `REJECTED_ALTERNATIVES.md` の
   案 C (jboss.server.log.dir) か案 D (エフェメラルボリューム間接リンク) を検討すること。
2. **EFS のパーミッション**: コンテナの実行ユーザー (例: jboss, uid=185) が
   `/mnt/logs` `/mnt/data` に書けるよう、EFS アクセスポイント
   (ownerUid/ownerGid/permissions) の利用を推奨。
   また `efs-entrypoint.sh` は冒頭で **`umask 002`** を設定する。既定の
   umask 022 では作成するディレクトリが `0755` (group に write 権限なし) となり、
   EFS アクセスポイントで同一 gid・別 uid の後続タスクが `mid/<タスクID>`
   ディレクトリを作成/更新できず失敗しうる。`umask 002` により `0775`
   (group write 可) で作成させ、タスク ID ディレクトリの作成失敗を防ぐ。
3. **古いタスク ID ディレクトリの削除**: `mid/` 配下は起動のたびに増える。
   ライフサイクル管理 (EFS の IA/アーカイブ、または定期削除バッチ) を用意すること。
4. **dangling リンクは正常**: ビルド直後のイメージ内ではリンク先が存在しないため
   リンクは「切れて」見えるが、ECS が EFS をマウントしエントリポイントが
   実体を作った時点で解決される。`docker run` をローカルで行う場合は
   `-v` で `/mnt/logs` `/mnt/data` に書き込み可能なボリュームを与えること。
5. **改行コード**: `entrypoint.sh` は LF 必須。base の Dockerfile 内で
   `sed -i 's/\r$//'` により CRLF 混入を除去している。
