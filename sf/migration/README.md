# フォルダ階層 → コンテンツライブラリ 移行フロー

Windows のフォルダ階層を、Salesforce のコンテンツライブラリへ階層ごと移行する。

- **input** — ローカルのルートフォルダ（配下のサブフォルダとファイル）
- **output** — ルートフォルダ名のライブラリ、同じ階層のフォルダ、配置済みのファイル、対応表 CSV

## クイックスタート

```powershell
cd <リポジトリルート>

# 1. まず必ず DryRun で対象を確認する（Salesforce へは一切書き込まない）
./scripts/migration/Import-FolderToLibrary.ps1 -RootPath 'D:\Docs\ProjectA' -DryRun

# 2. 問題なければ実行
./scripts/migration/Import-FolderToLibrary.ps1 -RootPath 'D:\Docs\ProjectA'
```

出力は `./migration-output/` に生成される（Git 管理外）。

| 出力                         | 内容                                              |
| ---------------------------- | ------------------------------------------------- |
| `<DeveloperName>-<日時>.csv` | 階層・ファイル名・ContentDocumentId の対応表      |
| `apex/*.apex`                | 実行された匿名 Apex（そのまま監査・再実行できる） |

## 主なオプション

| オプション        | 既定                                    | 説明                                                     |
| ----------------- | --------------------------------------- | -------------------------------------------------------- |
| `-RootPath`       | 必須                                    | 移行元ルートフォルダ                                     |
| `-LibraryName`    | ルートフォルダ名                        | ライブラリの表示名                                       |
| `-TargetOrg`      | sf の既定接続先                         | 接続先組織のエイリアス                                   |
| `-OutDir`         | `./migration-output`                    | CSV と Apex の出力先                                     |
| `-MaxFileSizeMB`  | `37`                                    | これを超えるファイルはスキップ                           |
| `-ExcludePattern` | `Thumbs.db`, `.DS_Store`, `desktop.ini` | 除外するファイル名                                       |
| `-Force`          | off                                     | 既存ファイル確認を省略（**重複するので通常は使わない**） |
| `-DryRun`         | off                                     | 走査のみ。書き込みなし                                   |

## CSV の列

| 列                  | 説明                                                    |
| ------------------- | ------------------------------------------------------- |
| `LibraryName`       | ライブラリ表示名                                        |
| `FolderPath`        | ライブラリ内のフォルダパス（ルート直下は空）            |
| `FileName`          | ファイル名（拡張子込み）                                |
| `RelPath`           | 移行元ルートからの相対パス                              |
| `SizeBytes`         | ファイルサイズ                                          |
| `ContentDocumentId` | 格納された ContentDocument の ID                        |
| `ContentVersionId`  | 今回作成した ContentVersion の ID（既存スキップ時は空） |
| `FolderId`          | 格納先 ContentFolder の ID                              |
| `Status`            | `Uploaded` / `AlreadyExists` / `Skipped` / `Failed`     |
| `Error`             | 失敗・スキップの理由                                    |

移行しなかったファイルも行として残す。移行元との突合ができなくなるため。

## 処理の流れ

```
Phase 0  ローカルフォルダを走査          PowerShell
Phase 1  ライブラリ作成                  匿名 Apex （単独トランザクション必須）
Phase 2  フォルダ階層作成                匿名 Apex （深さごとに一括 insert）
Phase 2.5 既存ファイルの棚卸し           匿名 Apex （重複アップロード防止）
Phase 3  ファイルアップロード            REST API （ContentVersion）
Phase 4  フォルダへ配置                  匿名 Apex （ContentFolderMember 一括 update）
Phase 5  CSV 出力                        PowerShell
```

### なぜ匿名 Apex だけで完結しないのか

**匿名 Apex はローカルファイルシステムを読めない。** そのため、ファイルのバイト列を
Salesforce へ渡す工程だけは、クライアント側（本スクリプト）が REST API で行う必要がある。
Salesforce 側の構造操作（ライブラリ・フォルダ・配置）は匿名 Apex に寄せてあり、
生成された `.apex` は `migration-output/apex/` に残るのでレビューできる。

### なぜフェーズを分けるのか

`ContentWorkspace` と `ContentFolder` を同一トランザクションで DML すると
**MIXED_DML_OPERATION** で失敗する（設定オブジェクトと非設定オブジェクトの混在）。
このため Phase 1 と Phase 2 は必ず別々の Apex 実行に分けている。

なお、`ContentFolder` と `ContentVersion` の混在は問題ない。

### ファイルがフォルダに入る仕組み

`ContentFolderMember` は API から作成できない（`createable=false`）。
ファイルは `ContentVersion.FirstPublishLocationId` にライブラリ ID を指定して
**まずライブラリ直下に入り**、その際に自動生成される `ContentFolderMember` の
`ParentContentFolderId` を更新することで目的のフォルダへ移動する。これが Phase 4。

## 再実行について

再実行は安全。ライブラリ・フォルダは既存を再利用し、ファイルは
「同じフォルダに同名のファイルがあればスキップ」する。
中断した移行の再開にもそのまま使える。

ライブラリの突合キーは `DeveloperName`。日本語のライブラリ名は英数字化すると
情報が落ちて別ライブラリと衝突するため、元の名前の MD5 先頭 8 桁を付与している
（例: `ZZ 移行テスト` → `ZZ_f8f1abc9`）。同じ名前からは常に同じ値が出る。

## 制約と注意

- **37MB を超えるファイルはスキップされる。** REST API の base64 JSON 方式の上限。
  それ以上を扱う場合は multipart/form-data での実装追加が必要（最大 2GB）。
- **ファイルのタイトルは拡張子を除いた名前になる。** Salesforce の標準動作で、
  拡張子は `FileExtension` 項目が保持する。ダウンロード時は元のファイル名に戻る。
- 移行先は Developer Edition（本番系）。実行すると即時反映される。必ず `-DryRun` で確認すること。
- ライブラリを削除する場合、先に配下のファイル・フォルダを削除し、
  **ごみ箱も空にする**必要がある（`Database.emptyRecycleBin`）。残っていると
  `DEPENDENCY_EXISTS` で削除できない。
- 実行ユーザーには「Salesforce CRM Content の管理」権限が必要。

## トラブルシューティング

| 症状                                     | 対処                                                               |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `アクセストークンを取得できませんでした` | `sf org login web --alias dev` で再認証                            |
| `MIXED_DML_OPERATION`                    | フェーズをまたいで DML していないか確認（Phase 1 と 2 は分離必須） |
| ファイルが重複した                       | `-Force` を付けていないか確認。重複分は ContentDocument を削除     |
| 特定ファイルだけ `Failed`                | CSV の `Error` 列を確認。多くはサイズ超過かファイル名の文字種      |

失敗した Apex は `migration-output/apex/` にそのまま残るので、
`sf apex run --file <path>` で個別に再実行して切り分けできる。
