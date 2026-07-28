module project_map.recognizer;

import std.algorithm.searching : all, any, canFind;
import std.algorithm.sorting : sort;
import std.array : array, empty;
import std.conv : to;
import std.datetime : Clock;
import std.digest : toHexString;
import std.digest.sha : sha1Of;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, getSize, isDir, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, extension, isAbsolute;
import std.string : indexOf, splitLines, strip, toLower;
import std.typecons : Nullable, nullable;

import json5;
import sdlang;

import project_map.path_util;
import project_map.types;

/// Stack / project-type recognizer (ported and generalized from DevCentr).
class ProjectRecognizer
{
    private RecognitionRule[] rules;
    private ViewOptions options;

    this(RecognitionRule[] rules, ViewOptions options = ViewOptions.init)
    {
        enforce(!rules.empty, "At least one recognition rule is required.");
        this.rules = rules.dup;
        this.options = patchOptions(options);
    }

    static ProjectRecognizer fromProfilesDir(string profilesDir, ViewOptions options = ViewOptions.init)
    {
        enforce(exists(profilesDir), "Recognition profiles directory does not exist: " ~ profilesDir);
        enforce(isDir(profilesDir), "Recognition profiles path is not a directory: " ~ profilesDir);

        string[] profileFiles;
        foreach (entry; dirEntries(profilesDir, SpanMode.shallow))
        {
            if (entry.isDir)
                continue;
            auto ext = extension(entry.name).toLower();
            if (ext != ".json" && ext != ".json5" && ext != ".sdl")
                continue;
            profileFiles ~= entry.name;
        }
        enforce(!profileFiles.empty, "No profiles found in: " ~ profilesDir);
        sort(profileFiles);

        RecognitionRule[] allRules;
        foreach (profilePath; profileFiles)
        {
            auto content = readText(profilePath);
            auto ext = extension(profilePath).toLower();
            if (ext == ".sdl")
                allRules ~= parseRuleContainerFromSdl(content, profilePath);
            else
                allRules ~= parseRuleContainer(parseJSON5(content), profilePath);
        }
        enforce(!allRules.empty, "No recognition rules loaded from: " ~ profilesDir);
        return new ProjectRecognizer(allRules, options);
    }

    /// Recognize stacks under projectRoot. Does not classify file roles.
    ProjectScan recognize(string projectRoot, bool saveToCache = false)
    {
        enforce(!projectRoot.empty, "Project root must not be empty.");
        auto absoluteRoot = absolutePath(projectRoot);
        auto projectFiles = collectProjectFiles(absoluteRoot, false);
        TechStackMatch[] matches;
        string[string] globallyClassified;

        foreach (rule; rules)
        {
            auto maybeMatch = evaluateRule(rule, absoluteRoot, projectFiles);
            if (maybeMatch.isNull)
                continue;
            auto match = maybeMatch.get();
            matches ~= match;
            foreach (filePath; match.relevantFiles)
                globallyClassified[filePath] = filePath;
        }
        buildHierarchy(matches);

        string[] unclassified;
        foreach (filePath; projectFiles)
        {
            if (filePath !in globallyClassified)
                unclassified ~= filePath;
        }
        sort(unclassified);

        auto scan = ProjectScan(
            absoluteRoot,
            baseName(absoluteRoot),
            Clock.currTime(),
            options.recognizerVersion,
            matches,
            unclassified,
            [],
            [],
            ""
        );

        if (saveToCache)
            scan.cacheFile = saveArchitectureModel(scan);
        return scan;
    }

    private ViewOptions patchOptions(ViewOptions opts) const @safe
    {
        ViewOptions patched = opts;
        if (patched.cacheRoot.length == 0)
            patched.cacheRoot = ".project-map/cache";
        if (patched.recognizerVersion.length == 0)
            patched.recognizerVersion = "0.2.0";
        return patched;
    }

    private static RecognitionRule[] parseRuleContainer(const JSONValue value, const string sourceLabel)
    {
        enforce(value.type == JSONType.object, "Recognition rule file must be a JSON object: " ~ sourceLabel);
        auto rulesField = jsonGetOptional(value, "rules");
        if (rulesField.type != JSONType.null_)
        {
            enforce(rulesField.type == JSONType.array, "`rules` must be an array in " ~ sourceLabel);
            RecognitionRule[] parsed;
            foreach (ruleValue; rulesField.array)
                parsed ~= parseRule(ruleValue, sourceLabel);
            enforce(!parsed.empty, "No rules in " ~ sourceLabel);
            return parsed;
        }
        return [parseRule(value, sourceLabel)];
    }

    private static RecognitionRule parseRule(const JSONValue value, const string sourceLabel)
    {
        enforce(value.type == JSONType.object, "Rule must be object in " ~ sourceLabel);
        RecognitionRule rule;
        rule.name = jsonExpectString(value, "name");
        rule.description = jsonGetStringOrDefault(value, "description");
        rule.parent = jsonGetStringOrDefault(value, "parent");
        rule.allOfFiles = jsonGetStringArray(value, "allOfFiles");
        rule.anyOfFiles = jsonGetStringArray(value, "anyOfFiles");
        rule.excludedFiles = jsonGetStringArray(value, "excludedFiles");
        rule.keywords = jsonGetStringArray(value, "keywords");
        foreach (manifestValue; jsonGetArray(value, "manifests"))
            rule.manifests ~= parseManifestRule(manifestValue, sourceLabel ~ " -> " ~ rule.name);
        return rule;
    }

    private static ManifestRule parseManifestRule(const JSONValue value, const string sourceLabel)
    {
        enforce(value.type == JSONType.object, "Manifest must be object in " ~ sourceLabel);
        ManifestRule rule;
        rule.pathPattern = jsonExpectString(value, "pathPattern");
        rule.format = jsonGetStringOrDefault(value, "format", "text");
        rule.required = jsonGetStringArray(value, "required");
        rule.anyOf = jsonGetStringArray(value, "anyOf");
        rule.dependencyFields = jsonGetStringArray(value, "dependencyFields");
        return rule;
    }

    private static RecognitionRule[] parseRuleContainerFromSdl(const string content, const string sourceLabel)
    {
        Tag root = parseSource(content, sourceLabel);
        auto rulesTag = root.getTag("rules");
        if (rulesTag !is null)
        {
            RecognitionRule[] parsed;
            foreach (tag; rulesTag.all.tags)
                parsed ~= parseRuleFromSdlRoot(tag, sourceLabel);
            enforce(!parsed.empty, "Empty SDL rules in " ~ sourceLabel);
            return parsed;
        }
        return [parseRuleFromSdlRoot(root, sourceLabel)];
    }

    private static RecognitionRule parseRuleFromSdlRoot(Tag root, const string sourceLabel)
    {
        RecognitionRule rule;
        auto nameTag = root.expectTag("name");
        enforce(!nameTag.values.empty, "SDL `name` required in " ~ sourceLabel);
        rule.name = nameTag.values[0].get!string;
        if (auto t = root.getTag("description"))
            if (!t.values.empty)
                rule.description = t.values[0].get!string;
        if (auto t = root.getTag("parent"))
            if (!t.values.empty)
                rule.parent = t.values[0].get!string;
        foreach (key; ["allOfFiles", "anyOfFiles", "excludedFiles", "keywords"])
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
                    case "keywords": rule.keywords = arr; break;
                }
            }
        }
        if (auto manifestsTag = root.getTag("manifests"))
            foreach (child; manifestsTag.all.tags)
                rule.manifests ~= parseManifestFromSdlTag(child, sourceLabel ~ " -> " ~ rule.name);
        return rule;
    }

    private static ManifestRule parseManifestFromSdlTag(Tag tag, const string sourceLabel)
    {
        ManifestRule rule;
        rule.pathPattern = tag.getAttribute!string("pathPattern", "");
        if (rule.pathPattern.empty && !tag.values.empty)
            rule.pathPattern = tag.values[0].get!string;
        enforce(!rule.pathPattern.empty, "manifest pathPattern required in " ~ sourceLabel);
        rule.format = tag.getAttribute!string("format", "text");
        if (auto t = tag.getTag("required"))
            foreach (v; t.values) rule.required ~= v.get!string;
        if (auto t = tag.getTag("anyOf"))
            foreach (v; t.values) rule.anyOf ~= v.get!string;
        if (auto t = tag.getTag("dependencyFields"))
            foreach (v; t.values) rule.dependencyFields ~= v.get!string;
        return rule;
    }

    private Nullable!TechStackMatch evaluateRule(const RecognitionRule rule, string absoluteRoot, const string[] projectFiles) const
    {
        if (!rule.allOfFiles.empty && !allPatternsSatisfied(rule.allOfFiles, projectFiles))
            return Nullable!TechStackMatch.init;
        if (!rule.anyOfFiles.empty && !anyPatternSatisfied(rule.anyOfFiles, projectFiles))
            return Nullable!TechStackMatch.init;
        if (!rule.excludedFiles.empty && anyPatternSatisfied(rule.excludedFiles, projectFiles))
            return Nullable!TechStackMatch.init;

        string[] relevantFiles = collectMatchingFiles(rule.allOfFiles ~ rule.anyOfFiles, projectFiles);
        sort(relevantFiles);

        auto keywordHits = evaluateKeywordHits(rule.keywords, absoluteRoot, relevantFiles, projectFiles);
        if (!rule.keywords.empty && keywordHits.length != rule.keywords.length)
            return Nullable!TechStackMatch.init;

        ManifestCheckResult[] manifestEvidence;
        if (!rule.manifests.empty && !evaluateManifestRules(rule.manifests, absoluteRoot, projectFiles, manifestEvidence))
            return Nullable!TechStackMatch.init;

        string[] inactiveFiles;
        if (options.includeInactiveFiles)
            inactiveFiles = buildInactiveFiles(projectFiles, relevantFiles);

        TechStackMatch match;
        match.name = rule.name;
        match.description = rule.description;
        match.parent = rule.parent;
        match.relevantFiles = relevantFiles;
        match.keywordHits = keywordHits;
        match.manifestEvidence = manifestEvidence;
        match.inactiveFiles = inactiveFiles;
        return nullable(match);
    }

    private void buildHierarchy(ref TechStackMatch[] matches) const
    {
        if (matches.length == 0)
            return;
        size_t[string] indexByName;
        foreach (idx, ref match; matches)
        {
            enforce(match.name.length != 0, "Tech stack match missing name.");
            enforce(!(match.name in indexByName), "Duplicate tech stack: " ~ match.name);
            indexByName[match.name] = idx;
        }
        string[][string] childrenByParent;
        foreach (ref match; matches)
        {
            if (match.parent.length == 0)
                continue;
            enforce(match.parent in indexByName, "Unknown parent `" ~ match.parent ~ "` for `" ~ match.name ~ "`.");
            childrenByParent[match.parent] ~= match.name;
        }
        foreach (ref match; matches)
        {
            if (auto listPtr = match.name in childrenByParent)
            {
                auto children = (*listPtr).dup;
                sort(children);
                match.children = children;
            }
            else
                match.children = [];
        }

        string[][string] aggregateCache;
        bool[string] recursionStack;

        string[] computeAggregate(string name)
        {
            if (auto cached = name in aggregateCache)
                return *cached;
            enforce(!(name in recursionStack), "Cycle in tech stack hierarchy: " ~ name);
            recursionStack[name] = true;
            auto index = indexByName[name];
            auto ref match = matches[index];
            string[string] total;
            foreach (file; match.relevantFiles)
                total[file] = file;
            foreach (childName; match.children)
                foreach (childFile; computeAggregate(childName))
                    total[childFile] = childFile;
            auto combined = total.byValue.array;
            sort(combined);
            aggregateCache[name] = combined;
            recursionStack.remove(name);
            return aggregateCache[name];
        }

        foreach (ref match; matches)
            match.aggregatedFiles = computeAggregate(match.name);
    }

    private string[] evaluateKeywordHits(const string[] keywords, string absoluteRoot, const string[] relevantFiles, const string[] allFiles) const
    {
        if (keywords.empty)
            return [];
        string[string] hits;
        string[] searchTargets = !relevantFiles.empty ? relevantFiles.dup : allFiles.dup;
        foreach (keyword; keywords)
        {
            auto hitFile = findKeywordInFiles(keyword, absoluteRoot, searchTargets);
            if (!hitFile.empty)
                hits[hitFile] = hitFile;
        }
        return hits.byValue.array;
    }

    private static string findKeywordInFiles(const string keyword, const string root, const string[] files)
    {
        foreach (relPath; files)
        {
            auto abs = buildPath(root, relPath);
            if (!exists(abs) || getSize(abs) > maxKeywordScanBytes)
                continue;
            string content;
            try
                content = readText(abs);
            catch (Exception)
                continue;
            if (content.canFind(keyword))
                return relPath;
        }
        return "";
    }

    private static bool evaluateManifestRules(const ManifestRule[] rules, const string root, const string[] files, ref ManifestCheckResult[] evidence)
    {
        foreach (rule; rules)
        {
            if (!evaluateManifestRule(rule, root, files, evidence))
                return false;
        }
        return true;
    }

    private static bool evaluateManifestRule(const ManifestRule rule, const string root, const string[] files, ref ManifestCheckResult[] evidence)
    {
        auto matches = collectMatchingFiles([rule.pathPattern], files);
        if (matches.empty)
            return false;
        foreach (relPath; matches)
        {
            auto manifestPath = buildPath(root, relPath);
            if (!exists(manifestPath))
                continue;
            ManifestCheckResult check;
            check.manifestPath = relPath;
            check.format = rule.format;
            string[] allDependencies;
            if (!loadDependenciesFromManifest(manifestPath, rule, allDependencies))
                continue;
            auto requiredSatisfied = intersection(rule.required, allDependencies);
            auto anySatisfied = intersection(rule.anyOf, allDependencies);
            if (!rule.required.empty && requiredSatisfied.length != rule.required.length)
                continue;
            if (!rule.anyOf.empty && anySatisfied.empty)
                continue;
            check.requiredSatisfied = requiredSatisfied;
            check.anySatisfied = anySatisfied;
            evidence ~= check;
            return true;
        }
        return false;
    }

    private static bool loadDependenciesFromManifest(const string manifestPath, const ManifestRule rule, ref string[] dependencies)
    {
        string content;
        try
            content = readText(manifestPath);
        catch (Exception)
            return false;
        final switch (rule.format.toLower())
        {
            case "json":
                return loadDependenciesFromJsonManifest(content, rule, dependencies);
            case "text":
                dependencies = collectDependenciesFromText(content);
                return true;
        }
    }

    private static bool loadDependenciesFromJsonManifest(const string content, const ManifestRule rule, ref string[] dependencies)
    {
        JSONValue json;
        try
            json = parseJSON5(content);
        catch (Exception)
        {
            try
                json = parseJSON(content);
            catch (Exception)
                return false;
        }
        if (json.type != JSONType.object)
            return false;
        string[] fields = !rule.dependencyFields.empty
            ? rule.dependencyFields.dup
            : ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"];
        string[string] collected;
        foreach (field; fields)
        {
            auto depValues = jsonGetObjectField(json, field);
            foreach (dependencyName, _; depValues)
                collected[dependencyName] = dependencyName;
        }
        dependencies = collected.byValue.array;
        sort(dependencies);
        return true;
    }

    private static string[] collectDependenciesFromText(const string content)
    {
        auto normalized = content.toLower();
        string[string] deps;
        foreach (line; normalized.splitLines())
        {
            auto stripped = line.strip();
            if (stripped.length == 0 || stripped[0] == '#')
                continue;
            auto commentPos = stripped.indexOf('#');
            if (commentPos != -1)
                stripped = stripped[0 .. cast(size_t) commentPos].strip();
            if (stripped.length == 0)
                continue;
            string candidate = stripped;
            auto bracketPos = candidate.indexOf('[');
            if (bracketPos != -1)
                candidate = candidate[0 .. cast(size_t) bracketPos];
            static immutable string[] separators = ["==", ">=", "<=", "~=", "!=", "=", ">", "<", " "];
            foreach (sep; separators)
            {
                auto pos = candidate.indexOf(sep);
                if (pos != -1)
                {
                    candidate = candidate[0 .. cast(size_t) pos];
                    break;
                }
            }
            candidate = candidate.strip();
            if (candidate.length)
                deps[candidate] = candidate;
        }
        auto values = deps.byValue.array;
        sort(values);
        return values;
    }

    private string saveArchitectureModel(const ProjectScan model)
    {
        auto cacheDir = resolveCacheDirectory(model.projectRoot);
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        auto cachePath = buildPath(cacheDir, buildCacheFileName(model.projectRoot));
        write(cachePath, model.toJSON(options).toPrettyString());
        return cachePath;
    }

    private string resolveCacheDirectory(const string projectRoot) const @safe
    {
        if (isAbsolute(options.cacheRoot))
            return options.cacheRoot;
        return buildPath(projectRoot, options.cacheRoot);
    }

    private static string buildCacheFileName(const string projectRoot)
    {
        auto hex = toHexString(sha1Of(projectRoot));
        auto projectId = baseName(projectRoot);
        if (projectId.length == 0)
            projectId = "project";
        return projectId ~ "-" ~ to!string(hex) ~ ".json";
    }

    private static string[] buildInactiveFiles(const string[] allFiles, const string[] activeFiles)
    {
        string[string] activeSet;
        foreach (file; activeFiles)
            activeSet[file] = file;
        string[] inactive;
        foreach (file; allFiles)
            if (file !in activeSet)
                inactive ~= file;
        sort(inactive);
        return inactive;
    }

    private static string[] intersection(const string[] expected, const string[] actual)
    {
        if (expected.empty)
            return [];
        string[string] found;
        foreach (value; expected)
            if (actual.canFind(value))
                found[value] = value;
        auto intersected = found.byValue.array;
        sort(intersected);
        return intersected;
    }
}

private JSONValue jsonGetOptional(const JSONValue value, const string key)
{
    enforce(value.type == JSONType.object, "JSON value must be an object.");
    if (auto entry = key in value.object)
        return *entry;
    return JSONValue.init;
}

private string jsonExpectString(const JSONValue value, const string key)
{
    auto maybe = jsonGetOptional(value, key);
    enforce(maybe.type != JSONType.null_, "Missing `" ~ key ~ "`.");
    enforce(maybe.type == JSONType.string, "`" ~ key ~ "` must be string.");
    return maybe.str;
}

private string jsonGetStringOrDefault(const JSONValue value, const string key, const string defaultValue = "")
{
    auto maybe = jsonGetOptional(value, key);
    if (maybe.type == JSONType.null_)
        return defaultValue;
    enforce(maybe.type == JSONType.string, "`" ~ key ~ "` must be string.");
    return maybe.str;
}

private string[] jsonGetStringArray(const JSONValue value, const string key)
{
    auto maybe = jsonGetOptional(value, key);
    if (maybe.type == JSONType.null_)
        return [];
    enforce(maybe.type == JSONType.array, "`" ~ key ~ "` must be array.");
    string[] result;
    foreach (element; maybe.array)
    {
        enforce(element.type == JSONType.string, "array `" ~ key ~ "` must be strings.");
        result ~= element.str;
    }
    return result;
}

private JSONValue[] jsonGetArray(const JSONValue value, const string key)
{
    auto maybe = jsonGetOptional(value, key);
    if (maybe.type == JSONType.null_)
        return [];
    enforce(maybe.type == JSONType.array, "`" ~ key ~ "` must be array.");
    return maybe.array;
}

private JSONValue[string] jsonGetObjectField(const JSONValue value, const string field)
{
    JSONValue[string] empty;
    if (value.type != JSONType.object)
        return empty;
    if (auto entry = field in value.object)
    {
        auto refValue = *entry;
        if (refValue.type == JSONType.object)
            return cast(JSONValue[string]) refValue.object;
    }
    return empty;
}
