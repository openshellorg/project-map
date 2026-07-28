module app;

import std.algorithm.searching : canFind, startsWith;
import std.array : join;
import std.conv : to;
import std.file : thisExePath;
import std.getopt;
import std.path : absolutePath, buildPath, dirName;
import std.process : environment;
import std.stdio;
import std.string : strip;

import project_map;

int main(string[] args)
{
    bool jsonOut = false;
    bool helpWanted = false;
    bool noHint = false;
    bool yesConfirm = false;
    bool emitOnly = false;
    string setAlias;
    string unsetAlias;
    string profilesRoot;
    string shellKind;
    string rcPath;
    string[] positionals;

    try
    {
        auto opts = getopt(
            args,
            std.getopt.config.passThrough,
            "j|json", "Machine-readable JSON output", &jsonOut,
            "y", "Confirm / non-interactive yes for --set", &yesConfirm,
            "e", "Emit alias snippet only (with --set); do not write rc", &emitOnly,
            "set", "Install shell alias: lsmap|lsf|lsg|gls|ls", &setAlias,
            "unset", "Remove a previously installed alias block", &unsetAlias,
            "profiles", "Path to profiles root (contains stacks/ and roles/)", &profilesRoot,
            "shell", "Shell kind for --set: bash|zsh|pwsh|nu", &shellKind,
            "rc", "RC / config path for --set/--unset", &rcPath,
            "no-hint", "Omit second TTY product hint line", &noHint,
            "h|help", "Show help", &helpWanted,
        );
        positionals = args[1 .. $];
        if (helpWanted || opts.helpWanted)
        {
            printHelp();
            return 0;
        }
    }
    catch (Exception ex)
    {
        stderr.writeln(osoCertLine(false));
        stderr.writeln("lsgrouped: " ~ ex.msg);
        return 2;
    }

    if (setAlias.length || unsetAlias.length)
        return handleSet(setAlias, unsetAlias, shellKind, rcPath, emitOnly, yesConfirm);

    string target = positionals.length ? positionals[0] : ".";
    if (profilesRoot.length == 0)
        profilesRoot = ProjectMapper.defaultProfilesRoot();

    ViewOptions view;
    view.includeStacks = true;
    view.includeRoles = true;
    view.includeEli5Hints = true;
    view.includeIcons = false;
    view.shallowListing = true;

    try
    {
        auto mapper = ProjectMapper.fromProfilesRoot(profilesRoot, view);
        auto scan = mapper.scan(target);

        if (jsonOut)
        {
            writeln(scan.toJSON(view).toPrettyString());
            return 0;
        }

        bool color = wantColor();
        writeln(osoCertLine(color));
        if (!noHint)
            writeln(lsgroupedHintPlain);
        writeln();

        if (scan.techStacks.length)
        {
            string[] names;
            foreach (s; scan.techStacks)
                names ~= s.name;
            writeln("Detected projects: " ~ names.join(", "));
            writeln();
        }

        foreach (g; scan.groups)
        {
            auto title = g.eli5Label.length ? g.eli5Label : g.rolePath;
            writeln(title);
            foreach (e; g.entries)
            {
                auto name = e.path;
                if (name.length && name[$ - 1] == '/')
                    name = name[0 .. $ - 1] ~ "/";
                writeln("  " ~ name);
            }
            writeln();
        }
        return 0;
    }
    catch (Exception ex)
    {
        stderr.writeln(osoCertLine(false));
        stderr.writeln("lsgrouped: " ~ ex.msg);
        return 1;
    }
}

int handleSet(string setAlias, string unsetAlias, string shellKind, string rcPath, bool emitOnly, bool yesConfirm)
{
    if (shellKind.length == 0)
        shellKind = detectShellKind();
    if (rcPath.length == 0)
        rcPath = defaultRcPath(shellKind);

    string binary = thisExePath();

    if (unsetAlias.length)
    {
        uninstallAlias(unsetAlias, rcPath, emitOnly);
        return 0;
    }

    if (setAlias == "ls" && !yesConfirm && !emitOnly)
    {
        stderr.writeln("About to install an *interactive* `ls` override (alias/function only).");
        stderr.writeln("Scripts that call /usr/bin/ls keep working; escape hatch: command ls / \\ls / ^ls");
        stderr.writeln("Re-run with -y to confirm: lsgrouped --set=ls -y");
        return 3;
    }

    installAlias(setAlias, binary, shellKind, rcPath, emitOnly);
    return 0;
}

void printHelp()
{
    writeln(osoCertLine(false));
    writeln();
    writeln("lsgrouped — list directory entries grouped by project role");
    writeln();
    writeln("Usage:");
    writeln("  lsgrouped [path]");
    writeln("  lsgrouped --json [path]");
    writeln("  lsgrouped --set=lsmap|lsf|lsg|gls|ls [-y] [-e] [--shell=bash|zsh|pwsh|nu]");
    writeln("  lsgrouped --unset=NAME");
    writeln();
    writeln("Not a drop-in replacement for ls. Prefer Nushell for a next-gen shell architecture");
    writeln("(typed pipelines), and use --json when scripting.");
    writeln();
    writeln("See man lsgrouped and https://opensh.org/");
}
