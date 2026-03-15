# Terminal Identity Overlay Spec

## 目的

focused terminal view および split view で、現在見ている terminal がどのワークスペースに属しているかを即座に識別できるようにする。
特に複数ワークスペースの terminal を同時表示した場合でも、ワークスペース境界と terminal 名を視覚的に把握できること。

## Cmd 押下時の見出し

- `Cmd` 押下中のみ、各 terminal の上端に `ワークスペース名 - ターミナルタイトル` を表示すること
- この見出しは Metal overlay として描画し、通常の AppKit subview を増やしてはならない
- 見出し文字は太字で描画すること
- 見出し背景は不透明ではなく、alpha `0.95` の準不透明色とすること
- 背景色と前景色は、可読性の高い組み合わせを決定論的に選ぶこと
- 見出しに追加の罫線やアクセント線は表示しないこと

## split view での Shift+Cmd 複数選択

- split view 上では、`Shift+Cmd+Click` で terminal の複数選択を行えること
- 選択された terminal は既存の青枠 selection 表現で示すこと
- `Shift+Cmd+Click` で追加・解除した選択は、`Cmd` を離すまでは保持すること
- `Shift` を先に離しても commit してはならないこと
- `Cmd` を離した時点で、選択 terminal 群だけを対象に split view を再構成すること
- 選択 terminal が 1 つだけだった場合は、その terminal を focused view で開くこと
- 既存 split から派生した split view では、`Cmd+Click` は terminal 最大化ではなく、直前の split 構成への復帰として動作すること
- 派生 split からさらに focused view や `Cmd+T` で新しい split を作った場合も、`Cmd+Click` で直前の split 構成へ戻れること

## split / focused lineage の状態遷移

- `split` には「現在表示している split 構成」とは別に、「`Cmd+Click` で戻る先の split 構成」を保持できること
- 仕様上、この 2 つは別物として扱うこと
- `return split` を持たない通常 split では、`Cmd+Click` は terminal 最大化として扱うこと
- `return split` を持つ派生 split では、`Cmd+Click` は terminal 最大化ではなく `return split` への復帰として扱うこと
- focused view も、split 由来である場合は `return split` を 1 つ保持できること
- split 由来の focused view では、`Cmd+Click` は常に `return split` への復帰として扱うこと

### 派生 split の生成規則

- `Shift+Cmd+Click` による subset split は、元になった split 全体を `return split` として保持すること
- split 由来の focused view から `Cmd+T` で新しい terminal を追加して split を作る場合、新しい split は現在表示用の split とは別に、元の split を `return split` として保持すること
- すでに `return split` を持つ派生 split 上で `Cmd+T` を実行した場合、新しい split は現在の controllers を更新しても、`return split` は上書きせず引き継ぐこと
- すでに `return split` を持つ派生 split から terminal を maximize して focused view に入った場合も、その focused view は同じ `return split` を引き継ぐこと

### 期待される代表遷移

- `通常 split -> Cmd+Click` は maximize になること
- `通常 split -> Shift+Cmd+Click(複数選択) -> 派生 split` になった時点で、`Cmd+Click` の意味は `Return to split` に変わること
- `通常 split -> maximize -> Cmd+T -> 派生 split` になった時点で、`Cmd+Click` の意味は `Return to split` に変わること
- `通常 split -> Shift+Cmd+Click(複数選択) -> 派生 split -> Cmd+T` のあとも、`Cmd+Click` の意味は `Return to split` のままであること
- `通常 split -> Shift+Cmd+Click(複数選択) -> 派生 split -> maximize -> Cmd+Click` で、subset split ではなく元の split 全体へ戻ること
- `通常 split -> maximize -> Cmd+T -> 派生 split -> Cmd+Click` で、2 terminal の派生 split ではなく元の split 全体へ戻ること

## Cmd 入力の検出

- `Cmd` 押下による見出し表示/非表示は、terminal が first responder でなくても反応すること
- 別ディスプレイ上に pterm が表示されていて window 非フォーカス時でも、`Cmd` 押下で見出しが出て、離したら消えること
- この global な監視は、見出し表示の ON/OFF にだけ使うこと
- 既存のショートカット処理や terminal 入力処理に干渉してはならない

## 色の決定規則

- 見出し色は固定パレットの単純ローテーションではなく、ワークスペース名から導く決定論的アルゴリズムで決めること
- 同じワークスペース名は常に同じ色であること
- 異なるワークスペース名は、可能な限り近接色に偏らないよう分散すること
- 前景色は背景色の明度に応じて自動選択し、可読性を優先すること

## split view の並び順

- split view では、同じワークスペースに属する terminal が隣接するように並べること
- 並び順は入力順ではなく、以下の比較キーで決定論的に安定させること
- 比較キー 1: `workspaceName`
- 比較キー 2: `terminal.title`
- 比較キー 3: `terminal.id`
- 同名ワークスペース、同名タイトルが存在しても、毎回同じ並び順になること

## ステータスバー案内

- ステータスバー左側には、既存の `Overview` / `Edit Notes` に加えて、以下の操作案内を表示すること
- `Cmd: Show identities`
- `Cmd+Click` の案内は presentation に応じて動的に切り替えること
- 親 split を持たない split view では `Cmd+Click: Maximize terminal`
- 既存 split から派生した split view では `Cmd+Click: Return to split`
- split 由来の focused view では `Cmd+Click: Return to split`
- overview および通常の focused view では `Cmd+Click` 案内を表示しないこと
- これらの案内は `|` セパレータで区切ること

## 回帰要件

- split view でワークスペース単位の隣接配置が崩れないこと
- 見出し文字列が focused / split の両方で正しく生成されること
- split view の `Shift+Cmd+Click` 複数選択が `Cmd` release でのみ commit されること
- 複数 workspace / 複数 terminal を含む split から subset split を作っても、`Cmd+Click` の戻り先が元の split 全体で安定すること
- split 由来の focused view から `Cmd+T` した場合も、`return split` lineage が失われないこと
- 派生 split からさらに `Cmd+T` した場合も、`return split` lineage が上書きされないこと
- `Cmd` 押下表示機能の追加で、既存ショートカットの挙動を壊さないこと
- ステータスバー案内追加で、Overview ボタンの表示/非表示やメトリクス右寄せを壊さないこと
