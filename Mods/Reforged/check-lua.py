#!/usr/bin/env python3
"""Compile-check Lua files without running them. Exit 1 on any syntax error.

Uses the Lua 5.4 runtime in lupa (pip install --user lupa). UE4SS runs Lua 5.4, so this check
must use the same version. The default lupa runtime is Lua 5.5, which allows more locals and
hid a load failure (#25). This replaces luacheck, which is not installable here without root.
It catches syntax errors and the 5.4 local limit only, not undefined globals.
"""
import sys

try:
    import lupa.lua54 as lupa_lua54
except ImportError:
    print("check-lua: lupa.lua54 is missing. Install lupa with its Lua 5.4 runtime "
          "(pip install --user lupa). The check did not run.", file=sys.stderr)
    sys.exit(1)

lua = lupa_lua54.LuaRuntime(unpack_returned_tuples=True)
print(f"check-lua: runtime {lua.eval('_VERSION')}")
status = 0
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        source = f.read()
    result = lua.eval("load")(source, "@" + path)
    # load returns the function on success, or (nil, message) on failure.
    if isinstance(result, tuple):
        print(f"{path}: {result[1]}", file=sys.stderr)
        status = 1
    else:
        print(f"{path}: syntax ok")
sys.exit(status)
