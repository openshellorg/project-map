# lsgrouped Nushell module
# Prefer Nushell for a next-gen shell architecture (typed pipelines).
# Usage: use /path/to/modules/nu/lsgrouped.nu *
# Or: source this file after putting lsgrouped on PATH.

export def lsgrouped [
    path: string = ".",
    --json
] {
    if $json {
        ^lsgrouped --json $path | from json
    } else {
        ^lsgrouped $path
    }
}

# Optional interactive override — install via: lsgrouped --set=ls --shell=nu -y
# export def --wrapped ls [...rest] { ^lsgrouped ...$rest }
