Ubuntu 26.04 で日本語入力するなら、標準の IBus + Mozc

- IBus は Ubuntu で標準的に使われる入力メソッド
- Mozc は Google開発のの日本語変換エンジン
[google/mozc](https://github.com/google/mozc)

```sh
sudo apt update
sudo apt install ibus-mozc
# 設定GUI
sudo apt install mozc-utils-gui
```

いったんログアウト→ログインすると確実

1. 右上の `A` / `あ` をクリック
2. **Keyboard Settings > Japanese (Mozc) > Preferences** を開く
3. **General > Keymap > Keymap style**
4. `Customize...` / **編集** を開く
5. 次の2つを追加

```text
Direct Input     henkan     Activate IME
Precomposition   henkan     Deactivate IME
```