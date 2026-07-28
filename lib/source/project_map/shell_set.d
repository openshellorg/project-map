module project_map.shell_set;

import std.array : join;
import std.file : append, exists, mkdirRecurse, readText, write;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : indexOf;

/// Supported short aliases and the interactive `ls` override.
enum string[] knownAliases = ["lsmap", "lsf", "lsg", "gls", "ls"];

string aliasSnippet(string aliasName, string binaryPath, string shellKind)
{
    auto target = binaryPath.length ? binaryPath : "lsgrouped";
    if (shellKind == "nu")
    {
        if (aliasName == "ls")
        {
            return "# lsgrouped: interactive ls override (escape with ^ls)\n"
                 ~ "export def --wrapped ls [...rest] { ^" ~ target ~ " ...$rest }\n";
        }
        return "export alias " ~ aliasName ~ " = ^" ~ target ~ "\n";
    }
    if (shellKind == "pwsh")
    {
        if (aliasName == "ls")
        {
            return "# lsgrouped: interactive ls override (escape: Get-Command ls -CommandType Application)\n"
                 ~ "function ls { & '" ~ target ~ "' @args }\n";
        }
        return "Set-Alias -Name " ~ aliasName ~ " -Value '" ~ target ~ "'\n";
    }
    // bash/zsh
    if (aliasName == "ls")
    {
        return "# lsgrouped: interactive ls override — escape with: command ls   or   \\ls\n"
             ~ "# WARNING: only affects interactive shells that source this rc; do not put ls on PATH.\n"
             ~ "alias ls='" ~ target ~ "'\n";
    }
    return "alias " ~ aliasName ~ "='" ~ target ~ "'\n";
}

string defaultRcPath(string shellKind)
{
    version (Windows)
    {
        auto home = environment.get("USERPROFILE", environment.get("HOME", "."));
        if (shellKind == "nu")
            return buildPath(home, "AppData", "Roaming", "nushell", "config.nu");
        if (shellKind == "pwsh")
            return buildPath(home, "Documents", "PowerShell", "Microsoft.PowerShell_profile.ps1");
        return buildPath(home, ".bashrc");
    }
    else
    {
        auto home = expandTilde("~");
        if (shellKind == "nu")
            return buildPath(home, ".config", "nushell", "config.nu");
        if (shellKind == "zsh")
            return buildPath(home, ".zshrc");
        return buildPath(home, ".bashrc");
    }
}

string detectShellKind()
{
    auto sh = environment.get("SHELL", "");
    if (sh.indexOf("zsh") >= 0)
        return "zsh";
    if (sh.indexOf("nu") >= 0)
        return "nu";
    version (Windows)
    {
        if (environment.get("NU_VERSION").length)
            return "nu";
        return "pwsh";
    }
    return "bash";
}

/// Append alias snippet to rc. Returns path written.
string installAlias(string aliasName, string binaryPath, string shellKind, string rcPath, bool dryRun)
{
    import std.algorithm.searching : canFind;
    enforceKnown(aliasName);
    if (aliasName == "ls")
    {
        stderr.writeln("WARNING: Installing interactive `ls` override as a shell alias/function only.");
        stderr.writeln("Never place a binary named `ls` earlier on PATH. Escape: command ls  /  \\ls  /  ^ls (Nu).");
    }
    auto snippet = aliasSnippet(aliasName, binaryPath, shellKind);
    auto marker = "# >>> lsgrouped " ~ aliasName ~ " >>>";
    auto block = marker ~ "\n" ~ snippet ~ "# <<< lsgrouped " ~ aliasName ~ " <<<\n";
    if (dryRun)
    {
        writeln(block);
        return rcPath;
    }
    auto dir = dirName(rcPath);
    if (!exists(dir))
        mkdirRecurse(dir);
    string existing = exists(rcPath) ? readText(rcPath) : "";
    if (existing.canFind(marker))
    {
        stderr.writeln("Alias block for `" ~ aliasName ~ "` already present in " ~ rcPath);
        return rcPath;
    }
    append(rcPath, (existing.length && existing[$ - 1] != '\n' ? "\n" : "") ~ block);
    stderr.writeln("Wrote `" ~ aliasName ~ "` to " ~ rcPath ~ " — reload your shell to apply.");
    return rcPath;
}

string uninstallAlias(string aliasName, string rcPath, bool dryRun)
{
    enforceKnown(aliasName);
    if (!exists(rcPath))
    {
        stderr.writeln("RC file not found: " ~ rcPath);
        return rcPath;
    }
    auto markerStart = "# >>> lsgrouped " ~ aliasName ~ " >>>";
    auto markerEnd = "# <<< lsgrouped " ~ aliasName ~ " <<<";
    auto content = readText(rcPath);
    auto start = content.indexOf(markerStart);
    if (start < 0)
    {
        stderr.writeln("No lsgrouped block for `" ~ aliasName ~ "` in " ~ rcPath);
        return rcPath;
    }
    auto end = content.indexOf(markerEnd, start);
    if (end < 0)
    {
        stderr.writeln("Malformed lsgrouped block for `" ~ aliasName ~ "` in " ~ rcPath);
        return rcPath;
    }
    end += markerEnd.length;
    if (end < content.length && content[cast(size_t) end] == '\n')
        end++;
    auto newContent = content[0 .. cast(size_t) start] ~ content[cast(size_t) end .. $];
    if (dryRun)
    {
        writeln(newContent);
        return rcPath;
    }
    write(rcPath, newContent);
    stderr.writeln("Removed `" ~ aliasName ~ "` block from " ~ rcPath);
    return rcPath;
}

private void enforceKnown(string aliasName)
{
    import std.algorithm.searching : canFind;
    import std.exception : enforce;
    enforce(knownAliases.canFind(aliasName),
        "Unknown alias `" ~ aliasName ~ "`. Known: " ~ knownAliases.join(", "));
}
