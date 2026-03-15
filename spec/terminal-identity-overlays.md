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
- focused view は、split 由来である場合に「いまいた split」と「その split が持つ return split」の 2 つを保持できること
- split 由来の focused view では、`Cmd+Click` は常に「いまいた split」への復帰として扱うこと

### 派生 split の生成規則

- 最初に通常 split から派生 split を作るとき、その通常 split を「始祖 split」として `return split` に記録すること
- いったん `return split` を持つ派生 split になった後は、`Shift+Cmd+Click` や `Cmd+T` でさらに派生 split を作っても、`return split` は常に最初に記録された始祖 split を維持すること
- つまり `A -> B -> C -> D` と派生した場合でも、`B`, `C`, `D` はすべて `A` を `return split` として持つこと
- split 由来の focused view は、「いま表示していた split」と、その split が持つ始祖 split を保持すること
- split 由来の focused view から `Cmd+T` で派生 split を作る場合、その新しい split は focused 元の split ではなく、保持していた始祖 split を `return split` として持つこと
- 派生 split 内で `Cmd+T` により terminal が追加された場合、その terminal は現在 split だけでなく始祖 split にも反映されること
- 派生 split / focused split lineage 内で `Cmd+W` や `exit` により terminal が消えた場合、現在 split だけでなく始祖 split からも同じ terminal が除去されること
- terminal 削除の結果として現在 split が成立しなくなっても、始祖 split に terminal が残っている限り overview に戻ってはならないこと
- overview に戻ってよいのは、始祖 split に属する terminal が 1 つも残っていない場合だけであること

### 期待される代表遷移

- `通常 split -> Cmd+Click` は maximize になること
- `通常 split -> Shift+Cmd+Click(複数選択) -> 派生 split` になった時点で、`Cmd+Click` の意味は `Return to split` に変わること
- `通常 split -> maximize -> Cmd+T -> 派生 split` になった時点で、`Cmd+Click` の意味は `Return to split` に変わること
- `通常 split -> Shift+Cmd+Click(複数選択) -> 派生 split -> Cmd+T` のあとも、`Cmd+Click` の意味は `Return to split` のままであること
- `通常 split A -> Shift+Cmd+Click(複数選択) -> 派生 split B -> Cmd+Click` で、`A` に戻ること
- `通常 split A -> Shift+Cmd+Click(複数選択) -> 派生 split B -> Shift+Cmd+Click(複数選択) -> 派生 split C -> Cmd+Click` でも、`A` に戻ること
- `通常 split A -> Shift+Cmd+Click(複数選択) -> 派生 split B -> Shift+Cmd+Click(複数選択) -> 派生 split C -> Shift+Cmd+Click(複数選択) -> 派生 split D -> Cmd+Click` でも、`A` に戻ること
- `通常 split A -> 派生 split B -> maximize -> focused -> Cmd+Click` では、`B` に戻ること
- その `B` で `Cmd+Click` した時に、`A` に戻ること

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
- split view では `Shift+Cmd+Click: Multi-select terminals` を表示すること
- `Cmd+Click` の案内は presentation に応じて動的に切り替えること
- 親 split を持たない split view では `Cmd+Click: Maximize terminal`
- 既存 split から派生した split view では `Cmd+Click: Return to split`
- split 由来の focused view では `Cmd+Click: Return to split`
- overview および通常の focused view では `Shift+Cmd+Click` / `Cmd+Click` 案内を表示しないこと
- これらの案内は `|` セパレータで区切ること

## 回帰要件

- split view でワークスペース単位の隣接配置が崩れないこと
- 見出し文字列が focused / split の両方で正しく生成されること
- split view の `Shift+Cmd+Click` 複数選択が `Cmd` release でのみ commit されること
- split view のステータスバーに `Shift+Cmd+Click: Multi-select terminals` が表示され、focused / overview では表示されないこと
- 複数 workspace / 複数 terminal を含む split から subset split を繰り返し作っても、`Cmd+Click` の戻り先が常に最初の split で安定すること
- split 由来の focused view から `Cmd+T` した場合も、保持していた始祖 split が失われないこと
- 派生 split からさらに `Cmd+T` / `Shift+Cmd+Click` した場合も、始祖 split の記録が上書きで失われないこと
- 派生 split で追加した terminal が `Cmd+Click` で始祖 split に戻った時にも見えていること
- 派生 split の terminal を `Cmd+W` / `exit` で減らした時、始祖 split に terminal が残っていれば overview ではなく残存 terminal を使って split / focused を再構成すること
- 始祖 split の最後の terminal が消えた時にだけ overview に戻ること
- `Cmd` 押下表示機能の追加で、既存ショートカットの挙動を壊さないこと
- ステータスバー案内追加で、Overview ボタンの表示/非表示やメトリクス右寄せを壊さないこと
