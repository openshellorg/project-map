module project_map.roles;

import std.algorithm.sorting : sort;
import std.array : array, empty;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, readText;
import std.path : buildPath, extension;
import std.string : toLower;
import std.typecons : Nullable, nullable;

import sdlang;

import project_map.path_util;
import project_map.types;

/// Loads and applies file-role profiles.
class RoleClassifier
{
    private RoleRule[] rules;

    this(RoleRule[] rules)
    {
        enforce(!rules.empty, "At least one role rule is required.");
        this.rules = rules.dup;
        sort!((a, b) => a.order < b.order)(this.rules);
    }

    static RoleClassifier fromProfilesDir(string profilesDir)
    {
        enforce(exists(profilesDir), "Role profiles directory missing: " ~ profilesDir);
        enforce(isDir(profilesDir), "Role profiles path is not a directory: " ~ profilesDir);

        string[] profileFiles;
        foreach (entry; dirEntries(profilesDir, SpanMode.shallow))
        {
            if (entry.isDir)
                continue;
            if (extension(entry.name).toLower() != ".sdl")
                continue;
            profileFiles ~= entry.name;
        }
        enforce(!profileFiles.empty, "No role SDL profiles in: " ~ profilesDir);
        sort(profileFiles);

        RoleRule[] allRules;
        foreach (path; profileFiles)
            allRules ~= parseRoleFromSdl(readText(path), path);
        return new RoleClassifier(allRules);
    }

    EntryClass[] classifyEntries(string absoluteRoot, const string[] listingPaths, const string[] stackNames)
    {
        EntryClass[] result;
        foreach (rel; listingPaths)
        {
            EntryClass ec;
            ec.path = rel;
            auto cleaned = stripTrailingSlash(rel);
            ec.absolutePath = buildPath(absoluteRoot, cleaned);
            ec.isDirectory = rel.length && rel[$ - 1] == '/';
            ec.stackAffiliations = stackNames.dup;

            auto matched = matchRole(rel);
            if (matched.isNull)
            {
                ec.roleId = "Unsorted";
                ec.rolePath = "Unsorted";
                ec.eli5Label = "Unsorted";
                ec.roleOrder = 10_000;
            }
            else
            {
                auto rule = matched.get();
                ec.roleId = rule.name;
                ec.rolePath = rule.rolePath.length ? rule.rolePath : rule.name;
                ec.eli5Label = rule.eli5Label.length ? rule.eli5Label : ec.rolePath;
                ec.iconId = rule.iconId;
                ec.roleOrder = rule.order;
            }
            result ~= ec;
        }
        return result;
    }

    GroupLayout[] buildGroups(EntryClass[] entries, bool includeIcons, bool includeEli5)
    {
        GroupLayout[string] byPath;
        foreach (e; entries)
        {
            auto key = e.rolePath.length ? e.rolePath : e.roleId;
            if (key !in byPath)
            {
                GroupLayout g;
                g.roleId = e.roleId;
                g.rolePath = e.rolePath;
                g.eli5Label = includeEli5 ? e.eli5Label : "";
                g.iconId = includeIcons ? e.iconId : "";
                g.order = e.roleOrder;
                byPath[key] = g;
            }
            byPath[key].entries ~= e;
        }
        GroupLayout[] groups = byPath.byValue.array;
        sort!((a, b) {
            if (a.order != b.order)
                return a.order < b.order;
            return a.rolePath < b.rolePath;
        })(groups);
        foreach (ref g; groups)
            sort!((a, b) => a.path < b.path)(g.entries);
        return groups;
    }

    private Nullable!RoleRule matchRole(string relPath)
    {
        foreach (rule; rules)
        {
            if (!rule.excludedFiles.empty && pathMatchesAnyPattern(relPath, rule.excludedFiles))
                continue;
            if (!rule.allOfFiles.empty && !allPatternsSatisfied(rule.allOfFiles, [relPath]))
                continue;
            if (!rule.anyOfFiles.empty)
            {
                if (pathMatchesAnyPattern(relPath, rule.anyOfFiles))
                    return nullable(rule);
            }
            else if (!rule.allOfFiles.empty)
            {
                return nullable(rule);
            }
        }
        return Nullable!RoleRule.init;
    }
}

private RoleRule parseRoleFromSdl(string content, string sourceLabel)
{
    Tag root = parseSource(content, sourceLabel);
    RoleRule rule;
    auto nameTag = root.expectTag("name");
    enforce(!nameTag.values.empty, "role `name` required in " ~ sourceLabel);
    rule.name = nameTag.values[0].get!string;
    if (auto t = root.getTag("rolePath"))
        if (!t.values.empty)
            rule.rolePath = t.values[0].get!string;
    if (auto t = root.getTag("eli5Label"))
        if (!t.values.empty)
            rule.eli5Label = t.values[0].get!string;
    if (auto t = root.getTag("iconId"))
        if (!t.values.empty)
            rule.iconId = t.values[0].get!string;
    if (auto t = root.getTag("order"))
    {
        if (!t.values.empty)
        {
            auto v = t.values[0];
            if (v.convertsTo!int)
                rule.order = v.get!int;
            else if (v.convertsTo!long)
                rule.order = cast(int) v.get!long;
            else
                rule.order = to!int(v.get!string);
        }
    }
    foreach (key; ["allOfFiles", "anyOfFiles", "excludedFiles"])
    {
        if (auto t = root.getTag(key))
        {
            string[] arr;
            foreach (v; t.values)
                arr ~= v.get!string;
            final switch (key)
            {
                case "allOfFiles": rule.allOfFiles = arr; break;
                case "anyOfFiles": rule.anyOfFiles = arr; break;
                case "excludedFiles": rule.excludedFiles = arr; break;
            }
        }
    }
    if (rule.rolePath.empty)
        rule.rolePath = rule.name;
    if (rule.eli5Label.empty)
        rule.eli5Label = rule.rolePath;
    return rule;
}
