module project_map.badge;

import std.process : environment;
import std.stdio : File, stdout;

/// Plain-text certification mark.
enum string osoCertPlain = "{OSO} Certified - opensh.org";

/// Truecolor `{OSO} Certified - opensh.org` for TTY (plan-locked hex).
string osoCertColored()
{
    return "\x1b[38;2;156;163;175m{\x1b[38;2;209;213;219mO"
         ~ "\x1b[38;2;184;92;92mS\x1b[38;2;90;155;176mO"
         ~ "\x1b[38;2;156;163;175m} \x1b[38;2;125;206;160mCertified"
         ~ "\x1b[38;2;156;163;175m - \x1b[38;2;59;110;165mopensh.org\x1b[0m";
}

bool wantColor()
{
    if (environment.get("NO_COLOR").length)
        return false;
    if (environment.get("OSO_FORCE_COLOR") == "1")
        return true;
    version (Windows)
    {
        import core.sys.windows.winbase : GetFileType, GetStdHandle, FILE_TYPE_CHAR, STD_OUTPUT_HANDLE;
        auto h = GetStdHandle(STD_OUTPUT_HANDLE);
        return GetFileType(h) == FILE_TYPE_CHAR;
    }
    else
    {
        import core.sys.posix.unistd : isatty;
        return isatty(stdout.fileno) != 0;
    }
}

string osoCertLine(bool color = wantColor())
{
    return color ? osoCertColored() : osoCertPlain;
}

enum string lsgroupedHintPlain =
    "lsgrouped — directory listing by role (optional interactive ls override; not a PATH replacement)";
