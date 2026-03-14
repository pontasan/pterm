# CPU Profiling Flow

`pterm` の CPU 使用率が高いときは、推測で触る前にまずプロファイルを採取する。

## 目的

- `pterm` 自身が CPU を消費しているのか確認する
- どの関数がホットパスかを特定する
- `sample` と Instruments `Time Profiler` の両方を残す

## 一発収集

```sh
make profile-cpu
```

既存プロセスへ付ける場合:

```sh
make profile-cpu-attach
```

出力は `.build/profiles/<timestamp>/` に保存される。

## 生成物

- `sample.txt`
  - `/usr/bin/sample` のスタックサンプリング結果
- `spindump.txt`
  - 対象を優先表示したスピンダンプ
- `time-profiler.trace`
  - Instruments の `Time Profiler` トレース
- `summary.txt`
  - `sample` の top-of-stack 要約

## 見る順番

1. `summary.txt`
   - top-of-stack の偏りをざっと見る
2. `sample.txt`
   - `Call graph` と `Sort by top of stack` を見る
3. `time-profiler.trace`
   - Instruments で self time / call tree を確認する

## 期待する判断

- 描画が主因なら:
  - `TerminalView.draw(in:)`
  - `IntegratedView.draw(in:)`
  - `MetalRenderer.render(...)`
  - `MetalRenderer.buildVertexData(...)`
  付近が上位に出る

- I/O や解析が主因なら:
  - `TerminalController.handlePTYOutput`
  - parser/model 更新
  付近が上位に出る

- メトリクス監視が主因なら:
  - `ProcessMetricsMonitor.sample`
  - `proc_pidinfo`
  - `proc_listchildpids`
  が目立つ

## ルール

- CPU 問題は、まずこのフローで採取してから直す
- `sample` と `Time Profiler` の両方で同じホットパスが見えるか確認する
- 場当たり対応ではなく、ホットパスの根本原因を潰す
