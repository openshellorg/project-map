module project_map.path_util;

import std.algorithm.searching : any;
import std.algorithm.sorting : sort;
import std.array : array;
import std.file : DirEntry, SpanMode, dirEntries;
import std.path : baseName, globMatch, relativePath;
import std.string : toLower;

string canonicalizePath(string path)
{
    char[] result = path.dup;
    foreach (ref char c; result)
    {
        if (c == '\\')
            c = '/';
    }
    return result.idup;
}

string stripTrailingSlash(string path)
{
    if (path.length && path[$ - 1] == '/')
        return path[0 .. $ - 1];
    return path;
}

bool matchesPattern(const string path, const string pattern)
{
    auto normalizedPath = toLower(canonicalizePath(path));
    auto normalizedPattern = toLower(canonicalizePath(pattern));
    if (globMatch(normalizedPath, normalizedPattern))
        return true;
    auto base = toLower(baseName(stripTrailingSlash(normalizedPath)));
    if (globMatch(base, normalizedPattern))
        return true;
    // Also try matching basename against pattern's basename
    auto patBase = toLower(baseName(normalizedPattern));
    if (patBase != normalizedPattern && globMatch(base, patBase))
        return true;
    return false;
}

bool pathMatchesAnyPattern(const string file, const string[] patterns)
{
    foreach (pattern; patterns)
    {
        if (matchesPattern(file, pattern) || matchesPattern(stripTrailingSlash(file), pattern))
            return true;
    }
    return false;
}

bool shouldSkipDirName(string name)
{
    auto n = name.toLower();
    static immutable skip = [
        ".git", "node_modules", ".dub", "target", "build", "dist",
        "__pycache__", ".venv", "venv", ".tox", "vendor", ".idea",
        ".vs", "coverage", ".next", ".nuxt", "out"
    ];
    foreach (s; skip)
        if (n == s)
            return true;
    return false;
}

/// Collect relative file paths under root, skipping heavy directories.
string[] collectProjectFiles(const string projectRoot, bool shallow = false)
{
    string[] files;
    if (shallow)
    {
        foreach (DirEntry entry; dirEntries(projectRoot, SpanMode.shallow))
        {
            auto relative = canonicalizePath(relativePath(entry.name, projectRoot));
            if (entry.isDir)
                files ~= relative ~ "/";
            else
                files ~= relative;
        }
    }
    else
    {
        void walk(string absDir, string relPrefix)
        {
            foreach (DirEntry entry; dirEntries(absDir, SpanMode.shallow))
            {
                auto name = baseName(entry.name);
                auto rel = relPrefix.length ? relPrefix ~ "/" ~ name : name;
                rel = canonicalizePath(rel);
                if (entry.isDir)
                {
                    if (shouldSkipDirName(name))
                        continue;
                    walk(entry.name, rel);
                }
                else
                {
                    files ~= rel;
                }
            }
        }
        walk(projectRoot, "");
    }
    sort(files);
    return files;
}

string[] collectMatchingFiles(const string[] patterns, const string[] files)
{
    string[string] found;
    foreach (file; files)
    {
        if (pathMatchesAnyPattern(file, patterns))
            found[file] = file;
    }
    auto unique = found.byValue.array;
    sort(unique);
    return unique;
}

bool allPatternsSatisfied(const string[] patterns, const string[] files)
{
    foreach (pattern; patterns)
    {
        if (!files.any!(file => matchesPattern(file, pattern)
                || matchesPattern(stripTrailingSlash(file), pattern)))
            return false;
    }
    return true;
}

bool anyPatternSatisfied(const string[] patterns, const string[] files)
{
    return files.any!(file => pathMatchesAnyPattern(file, patterns));
}
