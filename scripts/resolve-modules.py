#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""canonical ModulePlan resolver の CLI (実体は scripts/module_plan.py)。

module_plan はライブラリとしても使われる: consumer (render-bdebstrap.py 等) は
plan を自プロセス内で load_plan + verify してから使う (別プロセスでの検証に
依存しない)。
"""
from module_plan import main

if __name__ == "__main__":
    main()
