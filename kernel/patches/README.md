# kernel/patches/

`NNNN-説明.patch` の形式で置くと、ファイル名昇順に `git apply` される。

- E54C の DTS は patch ではなく `../dts/` に置いてある(in-tree に同名ファイルが
  存在しない場合のみコピーされる方式なので、7.3 で上流化されたら自動的に不要になる)
- vendor からの機能バックポートや revert はこちらに置く
