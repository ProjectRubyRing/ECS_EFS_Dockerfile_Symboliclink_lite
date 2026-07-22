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
        ├── current ──► <起動時刻-ランダム8桁>  (起動ごとに ln -sfn で張り替え)
        ├── <起動時刻-ランダム8桁-1>/       … 前々回起動の JBoss ログ (残存)
        ├── <起動時刻-ランダム8桁-2>/       … 前回起動の JBoss ログ (残存)
        └── <起動時刻-ランダム8桁-3>/       … 今回起動の JBoss ログ ◄─ current
    /mnt/data/pdf/                          … intra-web フロントの起動時に無ければ作成
```

> ディレクトリ名は例:`20260722103045-x7sk1z0e`
> (`起動時刻(YYYYMMDDhhmmss)` + `-` + `ランダム英数字8桁`)。
> ECS タスク ID を使う旧方式は `docker/base/entrypoint.taskid.sh` に保管している
> (下記 3 章および `REJECTED_ALTERNATIVES.md` 案 A' を参照)。

## 2. なぜこの構成なのか — readonlyRootFilesystem=true との両立

`readonlyRootFilesystem=true` のコンテナは、**起動後にルートファイルシステムへ
一切書き込めない**。したがって:

- ルート FS 側に置くもの (シンボリックリンク 3 種、既存 log ディレクトリの削除)
  は **必ずイメージビルド時 (Dockerfile の RUN)** に済ませる。
- 起動後に書き込みが必要なもの (ログ実体ディレクトリ、起動ごとのディレクトリ、
  `current` リンクの張り替え、`/mnt/data/pdf` の作成) は **すべて EFS マウント上**
  で行う。EFS ボリュームは readonlyRootFilesystem の制約対象外であり、
  タスク定義側で read-only 指定をしない限り書き込み可能。

この分担により、起動後のルート FS 書き込みはゼロになる。

## 3. JBoss EAP ログの「起動ごとの一意性」— 2 段リンク方式 (採用案)

### 課題

要件は `/opt/jboss-eap/standalone/log` を
`/mnt/logs/<コンテナ名>/logs/<サービス名>/mid/<一意名>` に向けること。
しかし **一意名 (元々は ECS タスク ID) はイメージビルド時には確定できない**。
同一イメージから何百ものタスクが起動されるため、ビルド時に一意値を焼き込んでも
「全タスクで共通」になってしまう。一方、リンク自体はビルド時に作るしかない
(2 章の制約)。

### 解決: リンクを 2 段に分ける

1. **ビルド時 (ルート FS 側)**:
   `/opt/jboss-eap/standalone/log → /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current`
   という「固定の」リンクを作成する。一意名を含まないためビルド時に確定できる。
2. **起動時 (EFS 側)**: エントリポイント `efs-entrypoint.sh` が
   - コンテナ起動時に `起動時刻(YYYYMMDDhhmmss)-ランダム英数字8桁` の一意名を生成する
   - `mid/<一意名>` ディレクトリを作成する (mkdir は原子的なので、同時起動でも衝突しない)
   - EFS 上のリンク `mid/current` を `ln -sfn <一意名> mid/current` で張り替える

JBoss がログを書くときのパス解決は
`/opt/jboss-eap/standalone/log` → `mid/current` → `mid/<今回の一意名>`
と 2 段で辿られ、**コンテナが起動し直すたびに新しいディレクトリへ書き込まれる**。
過去起動のディレクトリは EFS 上にそのまま残るため、
前の起動のログとの一意性が維持される。

### 一意ディレクトリ名の生成方式 — 起動時刻 + ランダム英数字 8 桁

ディレクトリ名は ECS タスク ID には依存せず、コンテナ起動時に自前で生成する。

- 形式: `起動時刻(YYYYMMDDhhmmss)` + `-` + `ランダム英数字8桁`
  (例: `20260722103045-x7sk1z0e`)。
- ランダム 8 桁は `[0-9a-z]` の 36 文字集合 (36^8 ≒ 2.8×10^12 通り)。
  生成は **`/dev/urandom` (暗号品質のエントロピー) を最優先**とし、
  使えない環境向けに `カーネル uuid` → `awk 乱数 (PID+ナノ秒シード)` へ多段
  フォールバックする。
- **同一 EFS を複数の ECS サービス・複数タスクが同時に使っても一意になる**。
  秒精度のタイムスタンプと高エントロピーな 8 桁の組み合わせで衝突確率は実質ゼロだが、
  さらに生成直後に `mkdir` で実在チェックし、万一衝突した場合は名前を引き直す
  (`mkdir` は原子的なので、同名を同時に狙った複数プロセスのうち成功するのは 1 つだけ)。

この方式では ECS メタデータエンドポイントを一切呼ばないため、ローカルの
`docker run` でもクラウドの ECS でも同じ挙動になる (環境差が無い)。

> **ECS タスク ID を使う旧実装について**
> ディレクトリ名に本物の ECS タスク ID を使う従来実装は
> `docker/base/entrypoint.taskid.sh` にそのまま保管している。
> `aws ecs describe-tasks` や CloudWatch のタスク ID とログを突き合わせたい
> 場合はこちらへ戻せる (base の Dockerfile の `COPY` 対象を差し替えるだけ)。
> トレードオフは `REJECTED_ALTERNATIVES.md` 案 A / 案 A' を参照。

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
  コンテナメタデータに `Name`、`TaskARN` (タスク ID) を含むため、環境変数を使わずに
  同じ情報を取得することも可能である。ただしこれはあくまで起動後の話であり、
  ビルド時のリンク作成には使えない。**現行実装 (`entrypoint.sh`) はメタデータ
  エンドポイントを一切使わず**、ミドルウェアログのディレクトリ名も
  「起動時刻-ランダム8桁」で自前生成する。タスク ID を用いる旧実装
  (`entrypoint.taskid.sh`) のみメタデータエンドポイントからタスク ID を取得する。

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
   タスクが `current` を自分の一意名へ張り替える。各タスクの実体ディレクトリ
   (`mid/<起動時刻-ランダム8桁>`) は一意なので **混ざらないが**、`current` は
   「最後に起動したタスク」を指すため、先行タスクがローテーションで新規作成する
   ファイルは後発タスクのディレクトリ側へ入り得る (open 済みファイルハンドルは
   影響なし)。この `current` 競合の性質はタスク ID 方式でも同じである。
   desiredCount=1 (ローリング時の一時 2 タスクは許容) なら実害はほぼ無いが、
   常時複数タスクで厳密な分離が必要なら `REJECTED_ALTERNATIVES.md` の
   案 C (jboss.server.log.dir) か案 D (エフェメラルボリューム間接リンク) を検討すること。
2. **EFS のパーミッション**: コンテナの実行ユーザー (例: jboss, uid=185) が
   `/mnt/logs` `/mnt/data` に書けるよう、EFS アクセスポイント
   (ownerUid/ownerGid/permissions) の利用を推奨。
3. **古い起動ディレクトリの削除**: `mid/` 配下は起動のたびに増える。
   ライフサイクル管理 (EFS の IA/アーカイブ、または定期削除バッチ) を用意すること。
   名前の接頭辞が起動時刻 (`YYYYMMDDhhmmss`) なので、更新時刻だけでなく
   ディレクトリ名でも新旧の並べ替え・世代削除がしやすい。
4. **dangling リンクは正常**: ビルド直後のイメージ内ではリンク先が存在しないため
   リンクは「切れて」見えるが、ECS が EFS をマウントしエントリポイントが
   実体を作った時点で解決される。`docker run` をローカルで行う場合は
   `-v` で `/mnt/logs` `/mnt/data` に書き込み可能なボリュームを与えること。
5. **改行コード**: `entrypoint.sh` は LF 必須。base の Dockerfile 内で
   `sed -i 's/\r$//'` により CRLF 混入を除去している。
