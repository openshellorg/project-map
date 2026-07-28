module project_map.scan;

import std.algorithm.iteration : map;
import std.array : array;
import std.datetime : Clock;
import std.exception : enforce;
import std.file : exists, isDir;
import std.path : absolutePath, baseName, buildPath, dirName;

import project_map.path_util;
import project_map.recognizer;
import project_map.roles;
import project_map.types;

/// High-level dual-axis scan (stacks + roles).
struct ProjectMapper
{
    ProjectRecognizer stackRecognizer;
    RoleClassifier roleClassifier;
    ViewOptions view;
    string stacksProfilesDir;
    string rolesProfilesDir;

    static ProjectMapper fromProfilesRoot(string profilesRoot, ViewOptions view = ViewOptions.init)
    {
        auto stacksDir = buildPath(profilesRoot, "stacks");
        auto rolesDir = buildPath(profilesRoot, "roles");
        enforce(exists(stacksDir) && isDir(stacksDir), "Missing profiles/stacks: " ~ stacksDir);
        enforce(exists(rolesDir) && isDir(rolesDir), "Missing profiles/roles: " ~ rolesDir);
        ProjectMapper pm;
        pm.view = view;
        pm.stacksProfilesDir = stacksDir;
        pm.rolesProfilesDir = rolesDir;
        if (view.includeStacks)
            pm.stackRecognizer = ProjectRecognizer.fromProfilesDir(stacksDir, view);
        if (view.includeRoles)
            pm.roleClassifier = RoleClassifier.fromProfilesDir(rolesDir);
        return pm;
    }

    /// Resolve default profiles directory next to the executable or from PROJECT_MAP_PROFILES.
    static string defaultProfilesRoot()
    {
        import std.process : environment;
        import std.file : thisExePath;
        if (auto env = environment.get("PROJECT_MAP_PROFILES"))
            if (env.length)
                return env;
        // apps/lsgrouped -> ../../profiles when running from build dir heuristics
        auto exeDir = dirName(thisExePath());
        auto candidates = [
            buildPath(exeDir, "profiles"),
            buildPath(exeDir, "..", "profiles"),
            buildPath(exeDir, "..", "..", "profiles"),
            buildPath(exeDir, "..", "..", "..", "profiles"),
        ];
        foreach (c; candidates)
        {
            auto stacks = buildPath(c, "stacks");
            if (exists(stacks) && isDir(stacks))
                return absolutePath(c);
        }
        return absolutePath(buildPath(exeDir, "..", "..", "profiles"));
    }

    ProjectScan scan(string path)
    {
        enforce(path.length != 0, "path must not be empty");
        auto root = absolutePath(path);
        enforce(exists(root) && isDir(root), "Not a directory: " ~ root);

        ProjectScan result;
        result.projectRoot = root;
        result.projectName = baseName(root);
        result.generatedAt = Clock.currTime();
        result.recognizerVersion = view.recognizerVersion;

        string[] stackNames;
        if (view.includeStacks && stackRecognizer !is null)
        {
            auto stackScan = stackRecognizer.recognize(root, false);
            result.techStacks = stackScan.techStacks;
            result.unclassifiedFiles = stackScan.unclassifiedFiles;
            foreach (s; result.techStacks)
                stackNames ~= s.name;
        }

        if (view.includeRoles && roleClassifier !is null)
        {
            auto listing = collectProjectFiles(root, view.shallowListing);
            result.entries = roleClassifier.classifyEntries(root, listing, stackNames);
            result.groups = roleClassifier.buildGroups(result.entries, view.includeIcons, view.includeEli5Hints);
        }
        return result;
    }
}
