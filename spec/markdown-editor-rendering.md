# Markdown Editor Rendering Spec

## 目的

ノート用マークダウンエディタは、ターミナルと同様に Metal を使って文字を描画する。
ただし編集責務そのものを独自実装へ置き換えるのではなく、TextKit を編集エンジンとして保持し、描画と入力演出のみを GPU 側へ分離する。

## アーキテクチャ

- 編集ソースは `NSTextView` / TextKit を使うこと
- 可視テキストの描画は `MTKView` ベースの Metal surface が担当すること
- `NSTextView` は glyph の通常描画を行わず、編集、選択、IME、Undo/Redo、find bar の責務のみを持つこと
- マークダウンハイライトは TextStorage 属性として保持し、Metal surface はその属性色を読んで描画すること

## 可視領域カリング

- Metal surface は、可視矩形と最小限の overscan 領域に含まれる glyph のみを描画対象にすること
- 非可視テキストは描画用 vertex を生成しないこと
- スクロール位置の変更時は、可視領域に応じて描画対象レンジを再計算すること
- 全文長に比例した毎フレーム描画は禁止

## パフォーマンス要件

- 描画は demand-driven とし、常時 60fps の連続レンダリングにしないこと
- 文字 vertex 配列は可視領域ぶんのみを保持すること
- GPU バッファは毎回新規確保せず、必要容量の範囲で再利用すること
- バッファ headroom は無制限に増やさず、可視領域に対して有界であること
- 可視領域、文書長、表示スケール、スクロール位置が変わっていない限り、基底 glyph vertex の再構築を避けること

## 入力演出

- 通常入力時はタイプライター打鍵音を再生できること
- IME の未確定入力でも打鍵音を再生できること
- 確定入力時は transient preview を Metal overlay として描画できること
- 入力演出は本文描画と同じ Metal surface 上で合成すること

## 表示品質

- macOS の実在する固定幅フォントを使うこと
- 非公開の system UI font 名に依存してはならない
- backing scale factor の変更時は glyph atlas と drawable size を同期更新すること
- 黒背景のダークテーマ前提で、属性色は markdown highlighter の結果に従うこと

## 回帰テスト

- 非空テキスト時に Metal surface が存在し、描画可能であること
- 長文文書で、描画対象レンジが全文より十分小さいこと
- スクロールで描画対象レンジが変化すること
- 既存のマークダウン自動整形、保存、dirty 管理、find bar、ウィンドウ仕様を壊さないこと
