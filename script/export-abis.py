#!/usr/bin/env python3
"""Export frontend ABIs + a complete custom-error selector table from the via-IR build (`out/`).

usage: script/export-abis.py <dest-dir>      (run `forge build` first; default profile = via-IR)
Writes <dest>/<Contract>.json (plain ABI arrays) and <dest>/errors-selectors.md:
  1. every custom error reachable in the exported ABIs, with selector and the ABIs that contain it;
  2. every custom error DECLARED in contract/errors/*.sol and error-declaring libraries, flagged when it is in no ABI
     (i.e. never thrown on any path the compiler kept), so dead declarations are visible.
"""
import json, os, subprocess, sys, re

CONTRACTS = ["SupaPoolManager", "SupaVault", "SupaRouter", "SupaQuoter", "SupaPositionManager", "SupaClaimsRouter",
             "SupaFeeCollector", "SupaTimelock", "CircuitBreaker", "PluginWhitelist", "SupaRoles", "LVRShieldPlugin",
             "AntiJITVestingPlugin", "CLAMMEngine", "BinAMMEngine", "StableAMMEngine", "VolatilityTWAPOracle",
             "PositionNFTDescriptor"]
ERROR_LIBS = [("contract/errors/" + f, f[:-4]) for f in sorted(os.listdir("contract/errors")) if f.endswith(".sol")]
ERROR_LIBS += [("contract/libraries/BinMathLib.sol", "BinMathLib"), ("contract/libraries/SafeCastLib.sol", "SafeCastLib")]


def canon(inp):
    t = inp["type"]
    if t.startswith("tuple"):
        return "(" + ",".join(canon(c) for c in inp["components"]) + ")" + t[5:]
    return t


def sig_selector(sig):
    return subprocess.run(["cast", "sig", sig], check=True, capture_output=True, text=True).stdout.strip()


def main(dest):
    os.makedirs(dest, exist_ok=True)
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain", "contract"], capture_output=True, text=True).stdout.strip()
    errs = {}
    for c in CONTRACTS:
        art = json.load(open(f"out/{c}.sol/{c}.json"))
        with open(os.path.join(dest, f"{c}.json"), "w") as f:
            json.dump(art["abi"], f, indent=2)
            f.write("\n")
        for e in art["abi"]:
            if e["type"] == "error":
                sig = f"{e['name']}({','.join(canon(i) for i in e['inputs'])})"
                errs.setdefault(sig, set()).add(c)
    sel = {s: sig_selector(s) for s in errs}
    declared = []
    for path, lib in ERROR_LIBS:
        out = subprocess.run(["forge", "inspect", f"{path}:{lib}", "errors", "--json"], capture_output=True, text=True)
        if out.returncode != 0:
            continue
        for s, h in json.loads(out.stdout).items():
            declared.append((lib, s, "0x" + h))
    abi_selectors = set(sel.values())
    lines = [f"# SupaDex custom errors — selectors (from via-IR ABIs, branch feat/remediation-2-2026-10-21 @ {head}"
             f"{' + uncommitted contract changes' if dirty else ''})", "",
             f"{len(errs)} distinct errors in the {len(CONTRACTS)} exported ABIs. Merge engine/plugin ABIs when decoding "
             "reverts: errors bubble up from engines and plugins.", "",
             "| selector | signature | emitted by (ABI) |", "|---|---|---|"]
    for s in sorted(errs, key=lambda x: x.lower()):
        lines.append(f"| {sel[s]} | {s} | {', '.join(sorted(errs[s]))} |")
    lines += ["", "## All declared errors (source libraries)", "",
              "`in ABI = no` means the error is declared but never thrown on any compiled path. The frontend can ignore it.", "",
              "| library | declared signature (UDVT names as in source) | selector | in ABI |", "|---|---|---|---|"]
    for lib, s, h in sorted(declared, key=lambda x: (x[0], x[1].lower())):
        lines.append(f"| {lib} | {s} | {h} | {'yes' if h in abi_selectors else 'no'} |")
    with open(os.path.join(dest, "errors-selectors.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"exported {len(CONTRACTS)} ABIs, {len(errs)} ABI errors, {len(declared)} declared errors @ {head}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "abis")
