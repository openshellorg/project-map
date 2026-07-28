module project_map.types;

import std.array : empty;
import std.datetime : SysTime;
import std.json : JSONValue;

/// Maximum file size (bytes) scanned for keyword matches.
immutable ulong maxKeywordScanBytes = 1_048_576;

/// How clients request populated fields from a scan.
struct ViewOptions
{
    bool includeStacks = true;
    bool includeRoles = true;
    bool includeIcons = false;
    bool includeEli5Hints = true;
    bool includeEvidence = false;
    bool includeInactiveFiles = false;
    bool shallowListing = true; /// Only immediate directory children for grouping
    string recognizerVersion = "0.2.0";
    string cacheRoot = ".project-map/cache";
}

/// Dependency-manifest check rule.
struct ManifestRule
{
    string pathPattern;
    string format = "text";
    string[] required;
    string[] anyOf;
    string[] dependencyFields;
}

/// Technology / project-type recognition profile.
struct RecognitionRule
{
    string name;
    string description;
    string parent;
    string[] allOfFiles;
    string[] anyOfFiles;
    string[] excludedFiles;
    string[] keywords;
    ManifestRule[] manifests;
}

/// File-role classification profile (for lsgrouped grouping).
struct RoleRule
{
    string name; /// Short id / display leaf, e.g. "Git"
    string rolePath; /// Hierarchical path, e.g. "Version control/Git"
    string eli5Label; /// Human label, e.g. "Version control -> Git"
    string iconId;
    int order = 100; /// Lower sorts first in layouts
    string[] allOfFiles;
    string[] anyOfFiles;
    string[] excludedFiles;
}

/// Evidence from a manifest check.
struct ManifestCheckResult
{
    string manifestPath;
    string format;
    string[] requiredSatisfied;
    string[] anySatisfied;

    JSONValue toJSON() const
    {
        JSONValue[string] obj;
        obj["path"] = JSONValue(manifestPath);
        obj["format"] = JSONValue(format);
        obj["requiredSatisfied"] = stringArrayToJSON(requiredSatisfied);
        obj["anySatisfied"] = stringArrayToJSON(anySatisfied);
        return JSONValue(obj);
    }
}

/// Matched technology stack.
struct TechStackMatch
{
    string name;
    string description;
    string parent;
    string[] children;
    string[] relevantFiles;
    string[] aggregatedFiles;
    string[] keywordHits;
    ManifestCheckResult[] manifestEvidence;
    string[] inactiveFiles;

    JSONValue toJSON() const
    {
        JSONValue[string] obj;
        obj["name"] = JSONValue(name);
        if (!description.empty)
            obj["description"] = JSONValue(description);
        if (!parent.empty)
            obj["parent"] = JSONValue(parent);
        obj["relevantFiles"] = stringArrayToJSON(relevantFiles);
        obj["aggregatedFiles"] = stringArrayToJSON(aggregatedFiles);
        obj["keywordHits"] = stringArrayToJSON(keywordHits);
        JSONValue[] manifests;
        foreach (m; manifestEvidence)
            manifests ~= m.toJSON();
        obj["manifests"] = JSONValue(manifests);
        obj["children"] = stringArrayToJSON(children);
        obj["inactiveFiles"] = stringArrayToJSON(inactiveFiles);
        return JSONValue(obj);
    }
}

/// One filesystem entry with classification metadata.
struct EntryClass
{
    string path; /// Relative path (or basename for shallow lists)
    string absolutePath;
    bool isDirectory;
    string roleId;
    string rolePath;
    string eli5Label;
    string iconId;
    string[] stackAffiliations;
    int roleOrder = 999;

    JSONValue toJSON(bool includeIcons, bool includeEli5) const
    {
        JSONValue[string] obj;
        obj["path"] = JSONValue(path);
        obj["absolutePath"] = JSONValue(absolutePath);
        obj["isDirectory"] = JSONValue(isDirectory);
        obj["roleId"] = JSONValue(roleId);
        obj["rolePath"] = JSONValue(rolePath);
        obj["roleOrder"] = JSONValue(roleOrder);
        obj["stackAffiliations"] = stringArrayToJSON(stackAffiliations);
        if (includeEli5 && !eli5Label.empty)
            obj["eli5Label"] = JSONValue(eli5Label);
        if (includeIcons && !iconId.empty)
            obj["iconId"] = JSONValue(iconId);
        return JSONValue(obj);
    }
}

/// Ordered group of entries (layout hint only; clients render).
struct GroupLayout
{
    string roleId;
    string rolePath;
    string eli5Label;
    string iconId;
    int order;
    EntryClass[] entries;

    JSONValue toJSON(bool includeIcons, bool includeEli5) const
    {
        JSONValue[string] obj;
        obj["roleId"] = JSONValue(roleId);
        obj["rolePath"] = JSONValue(rolePath);
        obj["order"] = JSONValue(order);
        if (includeEli5 && !eli5Label.empty)
            obj["eli5Label"] = JSONValue(eli5Label);
        if (includeIcons && !iconId.empty)
            obj["iconId"] = JSONValue(iconId);
        JSONValue[] ents;
        foreach (e; entries)
            ents ~= e.toJSON(includeIcons, includeEli5);
        obj["entries"] = JSONValue(ents);
        return JSONValue(obj);
    }
}

/// Full project scan result.
struct ProjectScan
{
    string projectRoot;
    string projectName;
    SysTime generatedAt;
    string recognizerVersion;
    TechStackMatch[] techStacks;
    string[] unclassifiedFiles;
    EntryClass[] entries;
    GroupLayout[] groups;
    string cacheFile;

    JSONValue toJSON(ViewOptions view = ViewOptions.init) const
    {
        JSONValue[string] obj;
        obj["projectRoot"] = JSONValue(projectRoot);
        obj["projectName"] = JSONValue(projectName);
        obj["generatedAt"] = JSONValue(generatedAt.toISOExtString());
        obj["recognizerVersion"] = JSONValue(recognizerVersion);
        if (!cacheFile.empty)
            obj["cacheFile"] = JSONValue(cacheFile);

        if (view.includeStacks)
        {
            JSONValue[] stacks;
            foreach (s; techStacks)
                stacks ~= s.toJSON();
            obj["techStacks"] = JSONValue(stacks);
            obj["unclassifiedFiles"] = stringArrayToJSON(unclassifiedFiles);
        }

        if (view.includeRoles)
        {
            JSONValue[] ents;
            foreach (e; entries)
                ents ~= e.toJSON(view.includeIcons, view.includeEli5Hints);
            obj["entries"] = JSONValue(ents);
            JSONValue[] grps;
            foreach (g; groups)
                grps ~= g.toJSON(view.includeIcons, view.includeEli5Hints);
            obj["groups"] = JSONValue(grps);
        }
        return JSONValue(obj);
    }
}

package JSONValue stringArrayToJSON(const string[] values)
{
    JSONValue[] result;
    foreach (value; values)
        result ~= JSONValue(value);
    return JSONValue(result);
}
