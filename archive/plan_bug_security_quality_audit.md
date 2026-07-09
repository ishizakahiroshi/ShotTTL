# [完了] ShotTTL バグ・セキュリティ・品質監査

> 最終更新: 2026-06-16(火) 00:45:41

## context配分

| 章 | 種別 | 概要 |
|---|---|---|
| C1 | plan | 監査スコープ・前提・禁止事項・確認観点の確定 |
| C2 | plan | 確定 finding（30 件）と却下 finding（蒸留ルール）の整理 |
| C3 | fix | 修正方針決定・実施・検証・既存機能影響確認 |

## C1 監査前提

### 作業目的

ShotTTL v0.1.0 公開準備の最終チェックとして、Windows / Unix 両系スクリプトと VBS ヘルパーに対し、(1) 削除系ツールとして致命的な安全性欠陥、(2) クロスプラットフォーム実装パリティの欠落、(3) 公開前に潰すべき品質・運用欠陥、を一網打尽にする。確定 finding を計画化し、修正・検証まで完遂する。

### 対象範囲

- `scripts/windows/shotttl.ps1`
- `scripts/windows/run-hidden.vbs`
- `scripts/windows/settings.example.json`
- `scripts/unix/shotttl.sh`
- `scripts/unix/settings.example.json`
- `README.md` / `README.ja.md` / `CLAUDE.md`
- `docs/task-scheduler-windows.md` / `docs/cron-linux.md` / `docs/launchd-macos.md`

### 除外範囲

- 撮影機能 / GUI / exe / インストーラー / 常駐アプリ（スコープ外）
- TrashTTL 構想（別プロダクト）
- 設定ファイルローダーの新規実装（v0.1.0 では未実装方針）

### DB を使わない前提

ShotTTL は永続 DB を持たない。状態は (a) 対象ディレクトリ内のファイル更新時刻、(b) ログファイル（`%APPDATA%\ShotTTL\logs\` / `~/.shotttl/logs/`）、(c) ユーザー設定（CLI 引数のみ。`settings.example.json` はサンプルで読み込まれない）、の 3 系統。DB スキーマ変更や migration の必要は一切ない。

### 状態管理・永続化方式の確認

- ログ: 日次ローテーション、append-only テキスト
- ロック: 現状なし（SEC-005 で追加検討）
- 設定: CLI 引数のみ（v0.1.0）

### 禁止事項

- 既定の Trash モードを Delete へ変更しない
- 危険フォルダ（ホーム / Desktop / Downloads / Documents / Pictures 直下と全配下）の拒否ロジックを緩めない
- Linux でゴミ箱コマンドが無い時に `rm` へフォールバックする実装を絶対に入れない
- 単独 exe・常駐プロセス・GUI を新規追加しない
- bash 4 以降専用構文（`${var,,}` 等）を導入しない（macOS 3.2 互換を維持）
- スクショ撮影 / 自動撮影 / クリップボード連携などスコープ外機能を足さない

### 現行機能維持の確認観点

- `--dry-run` / `-DryRun` で削除が一切発火しないこと
- 既定の Trash モードがゴミ箱経路で動作すること（Win=VisualBasic、macOS=`~/.Trash`、Linux=`gio`/`trash-put`/`kioclient`）
- 危険フォルダ拒否が引き続き機能すること（ホーム / Desktop / Downloads / Documents / Pictures 直下と配下）
- 許可リスト（Screenshots 系フォルダ）が引き続き通ること
- reparse point / symlink を target にすると拒否されること
- UNC パスが拒否されること
- 隠し / システムファイル / ドットファイルがスキップされること
- サブフォルダが既定で対象外であること
- ログ出力フォーマットが既存パーサ（あれば）と互換であること
- CLI フラグ名・別名・既定値が現状と一致すること

## C2 確定 finding 一覧

### 高 severity (high)

| ID | ファイル | 概要 |
|---|---|---|
| WIN-001 | `scripts/windows/shotttl.ps1` | `-IncludeSubfolders` で `Get-ChildItem -Recurse` がジャンクション/シンボリックリンクを辿り得る |
| U-1 | `scripts/unix/shotttl.sh` | 中間 symlink がアロウリスト / 危険リストをバイパス |
| DEP-001 | `scripts/windows/shotttl.ps1` | `Microsoft.VisualBasic.FileIO` が PowerShell 7 (.NET Core) で既定では利用不可 |
| F1-unix-mv-n-silent-noop | `scripts/unix/shotttl.sh` | macOS Trash 経路: `mv -n` の silent no-op で削除失敗が成功扱いになる |

### 中 severity (medium)

| ID | ファイル | 概要 |
|---|---|---|
| WIN-002 | `scripts/windows/shotttl.ps1` | ログファイルパスをプロセス起動時に 1 回キャッシュ、日跨ぎで前日ログに書き続ける |
| WIN-003 | `scripts/windows/shotttl.ps1` | ログ追記の共有モード未指定、同時実行で IOException |
| SEC-001 | 両スクリプト | アロウリスト方針とデニーリスト実装の乖離（仕様 vs 実装） |
| SEC-002 | `scripts/unix/shotttl.sh` | TOCTOU: find 列挙と rm/mv の間で symlink リダイレクトの余地 |
| VULN-SH-001 | `scripts/unix/shotttl.sh` | symlink エントリポイントのチェックが main flow でバイパスされる |
| VULN-PS-002 | `scripts/windows/shotttl.ps1` | `-IncludeSubfolders` で reparse 配下を辿る（WIN-001 と同根、別観点） |
| DEP-002 | `scripts/unix/shotttl.sh` | Trash バックエンドのバージョン未確認、失敗モードがログから区別困難 |
| M1 | 両スクリプト | 画像拡張子セットが両スクリプトで重複・同期保証なし |
| M2 | 両スクリプト | アロウリスト / 危険サブツリーリストが両スクリプト内外で重複 |
| M3 | 両スクリプト | 同じライフサイクルイベントのログ文言が OS 間で乖離 |
| M5 | docs / 両スクリプト | docs はアロウリストと記述、実装はデニーリスト + 例外 |

### 低 severity (low)

| ID | ファイル | 概要 |
|---|---|---|
| WIN-004 | `scripts/windows/shotttl.ps1` | `Add-Type -AssemblyName Microsoft.VisualBasic` がファイル毎に呼ばれる |
| U-3 | `scripts/unix/shotttl.sh` | `LOG_FILE` の日付が起動時固定、長時間ランで前日ログへ書き続ける |
| U-4 | `scripts/unix/shotttl.sh` | `find` のエラーが silent に握り潰される |
| U-5 | `scripts/unix/shotttl.sh` | `--retention-minutes=VALUE` 分岐で `value` を `local` していない |
| VBS-001 | `scripts/windows/run-hidden.vbs` | ユーザーが `-Quiet` を渡したとき重複付与される |
| VBS-002 | `scripts/windows/run-hidden.vbs` | `shell.Run` 失敗が wscript エラーダイアログになる |
| VBS-003 | `scripts/windows/run-hidden.vbs` | `Quote()` ループの非短絡 `And` が `Mid()` の寛容性に依存 |
| SEC-003 | `scripts/unix/shotttl.sh` | ログディレクトリが既定 umask、共有ホストで他者可読 |
| SEC-004 | `scripts/windows/run-hidden.vbs` | `powershell.exe` の PATH フォールバックで PATH ハイジャック懸念 |
| SEC-005 | 両スクリプト | 同時実行で同一ファイル競合 |
| DEP-004 | リポジトリルート | CI ワークフローなし、shellcheck / PSScriptAnalyzer 自動カバレッジなし |
| DEP-005 | `scripts/windows/run-hidden.vbs` | Windows 11 24H2+ で VBScript 廃止予定、推奨タスク設定への影響 |
| M4 | 両スクリプト | 保持上限 525600 が 3 箇所にハードコード |
| M7 | `scripts/unix/shotttl.sh` | パラメータ展開プレフィックスの `$target` 未クォート |
| F1 | `README.md` | `run-hidden.vbs` が `-Quiet` を自動付与する点が未記述 |
| F2 | `scripts/windows/settings.example.json` | CLI が PascalCase、設定例が camelCase でマッピング無し |
| F3 | `docs/launchd-macos.md` | plist の `/Users/YOUR_USER/Pictures/Screenshots` が手順 3 推奨パスへ未更新 |
| F4 | `README.md` | reparse point ファイルの Win/Unix 挙動差が未文書化 |
| F5 | `docs/cron-linux.md` | cron 環境で `HOME` 未設定時の挙動が未記述 |
| F3-linux-gio-failure-no-secondary-backend | `scripts/unix/shotttl.sh` | gio 実行時失敗で trash-put / kioclient へフォールバックしない |
| F4-macos-put-back-metadata-absent | `scripts/unix/shotttl.sh` | macOS Finder の Put Back が機能しない（mv のため） |
| F5-linux-gio-trash-stderr-leak | `scripts/unix/shotttl.sh` | Linux ゴミ箱コマンドの stderr が cron メールへ漏れる |

## 敵対的検証結果

確定 finding 30 件は別エージェントによる敵対的レビュー（PoC または実コードトレース要求）を通過。下記 12 件は再現不能・前提崩壊・主観的好みのため却下し、必要な要素は「確認済みルール」へ蒸留した。

### 却下 finding と蒸留先

| 却下 ID | 却下理由要約 |
|---|---|
| WIN-005 | 現コードは `-contains` exact match で順序依存バグなし。将来回帰リスクの提案にとどまる |
| WIN-006 | `$HOME` は read-only で再現コマンド不成立、denylist も同 prefix 依存で実害なし |
| U-2 | basename 独立チェック + `*/.*` の anywhere match で skip 意味は保たれる |
| U-6 | `tr [:upper:] [:lower:]` は ASCII 拡張子で具体的な失敗ケースなし |
| U-7 | アロウリスト優先順位はゼロコンフィグ UX 維持のための仕様 |
| CFG-001 | `settings.example.json` 冒頭の `note` で「v0.1.0 では CLI 引数へ転記」と明示済み |
| VULN-SH-003 | `pwd -P` がカーネル正規形バイト列を返すため allow/deny で割れない |
| DEP-003 | `~/Pictures` シンボリックリンク時も `return 1`（safe）へ落ち実害なし |
| M6 | 「resolver を共有しろ」は主観的なリファクタ提案、機能欠陥ではない |
| F2-windows-onlyerrordialogs-blocks-hidden | session 0 isolation と try/catch の存在でハングは発生しない |

## 確認済みルール

却下 finding から抽出した、今後の実装・レビュー判断で前提として扱うルール:

- 危険フォルダ判定は exact match と path-prefix の二段で機能している（順序依存のテスト追加は将来課題、コード変更は不要）
- `is_image_file` の小文字化は ASCII 拡張子前提で十分（多言語ロケール耐性強化は後回し）
- `settings.example.json` の `note` フィールドによる「v0.1.0 では未実装」明示は維持必須
- macOS `pwd -P` の正規化はカーネル/FS canonical 形バイト列を返す前提で allow/deny 比較を組む
- 共通リゾルバ抽出のような「コード組織」目的のリファクタは bug finding として扱わず、別途品質計画で扱う

## C3 修正方針

### 修正方針（severity 別）

- **high (4 件)**: 全件即修正。WIN-001 / VULN-PS-002 は自前再帰 + reparse 除外、U-1 は祖先 symlink 検査、DEP-001 は起動時 probe、F1-unix-mv-n-silent-noop は exit-code 依存を残存チェックへ置換
- **medium (12 件)**: v0.1.0 公開ブロッカーとして全件修正。ただし SEC-001 / M5 はドキュメント側で実装に揃える方針（実装をアロウリスト厳格化に倒すと既存ユーザーの `%TEMP%` 用例が壊れるため）
- **low (24 件)**: v0.1.0 では文書系（F1 / F2 / F3 / F5 / DEP-005）とパリティ系（M3 / M4）を優先、CI 系（DEP-004）と最適化系（WIN-004）はベストエフォート

### TODO チェックリスト

- [ ] WIN-001 / VULN-PS-002 修正: 自前再帰で reparse 検出時に降りない
- [ ] WIN-002 修正: ログパスをキャッシュせず毎回構築
- [ ] WIN-003 修正: ログ追記を共有モード対応 or Mutex 逐次化
- [ ] WIN-004 修正: `Add-Type` を起動時 1 回へ
- [ ] U-1 修正: 全祖先 symlink チェック追加
- [ ] U-3 修正: `log()` 内で日付計算
- [ ] U-4 修正: `find` stderr をログへ、PIPESTATUS で失敗検知
- [ ] U-5 修正: `local RETENTION_VALUE` で名前空間汚染回避
- [ ] VBS-001 修正: ユーザー指定 `-Quiet` を検出して重複回避
- [ ] VBS-002 修正: `shell.Run` を `On Error Resume Next` で包んでログ出力
- [ ] VBS-003 修正: `Len(s)` キャッシュと境界チェック分離
- [ ] SEC-001 / M5: README / CLAUDE.md を実装挙動（deny-list + allow 例外）に合わせる
- [ ] SEC-002 修正: 削除直前の `lstat` 再検査
- [ ] SEC-003 修正: ログディレクトリ 700 / ファイル 600 へ
- [ ] SEC-004 修正: `powershell.exe` PATH フォールバックを fail-loud 化
- [ ] SEC-005 修正: 起動時ファイルロック取得、失敗で exit 0
- [ ] VULN-SH-001 修正: `is_unsafe_target` を `normalize_path` 前後で二段適用
- [ ] DEP-001 修正: 起動時に `[Microsoft.VisualBasic.FileIO.FileSystem]` probe
- [ ] DEP-002 修正: バックエンド version をログへ、`trash-put` 優先検討
- [ ] DEP-004 修正: shellcheck + PSScriptAnalyzer の最小 CI 追加
- [ ] DEP-005 修正: `docs/task-scheduler-windows.md` に Windows 11 24H2+ 代替手順追記
- [ ] M1 修正: 両スクリプトに相互参照コメント
- [ ] M2 修正: アロウリスト / 危険リストを各スクリプト内で 1 箇所に集約
- [ ] M3 修正: ログ文言を `Removed via Trash:` / `Removed via Delete:` に統一
- [ ] M4 修正: bash 側に `readonly MAX_RETENTION_MINUTES`、PS 側に同期コメント
- [ ] M7 修正: `${file#"$target/"}` へクォート
- [ ] F1 修正: README / docs に「`run-hidden.vbs` は `-Quiet` を自動付与」明記
- [ ] F2 修正: settings.example.json にマッピング表 or v0.1.0 で削除検討
- [ ] F3 修正: `docs/launchd-macos.md` の plist 例を `~/ShotsInbox` で完結
- [ ] F4 修正: README に reparse ファイル挙動の Win/Unix 差を明記 or unix 側で `! -type l` 追加
- [ ] F5 修正: `docs/cron-linux.md` に `HOME` 未設定時の注意追記
- [ ] F1-unix-mv-n-silent-noop 修正: ソース残存チェックで mv -n の silent no-op を検知
- [ ] F3-linux-gio-failure-no-secondary-backend 修正: 各バックエンドを「成功 return / 失敗で次へ」へ
- [ ] F4-macos-put-back-metadata-absent 修正: README/docs に Put Back 非対応を明記（実装変更なし）
- [ ] F5-linux-gio-trash-stderr-leak 修正: 4 バックエンド呼び出しに `2>>"$LOG_FILE"`

## 調査ログ

- 2026-06-16 00:45: 監査スコープ確定、敵対的レビュー完了、確定 30 件 / 却下 12 件で計画化。

## 実施した修正

<TODO: 各 finding 修正時に追記>

## 実行した検証

<TODO: 検証実施時に追記>

## 実行しなかった検証と理由

<TODO: 必要に応じて追記>

## 既存機能への影響確認

<TODO: 修正完了後に「現行機能維持の確認観点」を全項目チェックして記録>

## 残課題

<TODO: 完了時点で v0.1.0 範囲外の積み残しを列挙>

## 判断待ち事項

なし。

## パスした項目

却下 finding 12 件（C2「敵対的検証結果」を参照）。

## 進言事項

- SEC-001 / M5 は「実装を仕様に揃える」のではなく「ドキュメントを実装に揃える」方向で進めることを推奨。理由は既存の `%TEMP%\shotttl-test` 用例と「他フォルダにも自前判断で使える」というゼロコンフィグ性が崩れるため。
- DEP-004 (CI) は v0.1.0 ブロッカーとせず、公開直後の patch リリースで導入する案を進言。
- F4 は実装変更（unix 側 `! -type l` 追加）よりドキュメント明記の方が安全（既存の symlink 利用者を壊さない）。

## 完了条件

- TODO チェックリスト全項目クローズ
- 「現行機能維持の確認観点」全項目で regression なし
- README / CLAUDE.md / docs が実装挙動と整合
- `--dry-run` で実ファイル削除が一切発生しないことを Win/Unix 双方で確認
- 危険フォルダ拒否 / アロウリスト通過 / reparse 拒否 / UNC 拒否を Win/Unix 双方で再確認

## 最終結果

<TODO: 完了時に記入し、H1 ラベルを [完了] へ更新>
