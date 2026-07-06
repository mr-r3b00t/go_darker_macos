#!/usr/bin/env bash
#
# enum_telemetry.sh — Enumerate and harden telemetry / analytics configuration
# on macOS (OS-level diagnostics + Safari).
#
# Usage:
#   ./enum_telemetry.sh                interactive menu
#   ./enum_telemetry.sh --status       full read-only enumeration, then exit
#   ./enum_telemetry.sh --view         table of all managed keys: current vs recommended
#   ./enum_telemetry.sh --harden-all   apply items 1-5 without the menu (still confirms)
#
# Notes:
#   * Written for the stock macOS bash 3.2 — no associative arrays etc.
#   * All writes are preceded by a plist backup under ./telemetry_backups/.
#   * Item 1 (system-wide analytics) needs sudo; everything else is per-user.
#   * Safari preferences live in Safari's sandbox container. Without Full Disk
#     Access for your terminal, reads show <not set> and writes may not stick.
#   * Quit Safari before applying Safari items (the script offers to).

set -u

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)

DMH="/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
SAFARI_CONTAINER="$HOME/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"
BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)/telemetry_backups/$(date '+%Y%m%d_%H%M%S')"

# Prefer the sandboxed container plist when readable (needs Full Disk Access)
if [[ -r "$SAFARI_CONTAINER" ]] && defaults read "$SAFARI_CONTAINER" &>/dev/null; then
    SAFARI="$SAFARI_CONTAINER"
    SAFARI_MODE="container plist (Full Disk Access OK)"
else
    SAFARI="com.apple.Safari"
    SAFARI_MODE="domain fallback — grant Full Disk Access for reliable results"
fi

section() { printf '\n%s========== %s ==========%s\n' "$BOLD" "$1" "$RESET"; }
ok()      { printf '%s%s%s'   "$GREEN"  "$1" "$RESET"; }
bad()     { printf '%s%s%s'   "$RED"    "$1" "$RESET"; }
warn()    { printf '%s%s%s'   "$YELLOW" "$1" "$RESET"; }

# dread <domain-or-plist> <key> — prints value, or "unset" if absent
dread() { defaults read "$1" "$2" 2>/dev/null || echo "unset"; }

# print_key <domain> <key> <label>
print_key() {
    local v; v=$(dread "$1" "$2")
    [[ "$v" == "unset" ]] && v="<not set / default>"
    printf '%-55s %s\n' "$3:" "$v"
}

confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# ---------------------------------------------------------------------------
# Backups — copy the plists we may touch, once per run, before the first write
# ---------------------------------------------------------------------------
BACKED_UP=0
backup_plists() {
    [[ $BACKED_UP -eq 1 ]] && return 0
    mkdir -p "$BACKUP_DIR"
    local p
    # Container plist gets a distinct name — same basename as the fallback plist
    [[ -r "$SAFARI_CONTAINER" ]] && \
        cp "$SAFARI_CONTAINER" "$BACKUP_DIR/com.apple.Safari.container.plist" 2>/dev/null
    for p in \
        "$DMH" \
        "$HOME/Library/Preferences/com.apple.Safari.plist" \
        "$HOME/Library/Preferences/com.apple.assistant.support.plist" \
        "$HOME/Library/Preferences/com.apple.AdLib.plist" \
        "$HOME/Library/Preferences/com.apple.SubmitDiagInfo.plist"
    do
        [[ -r "$p" ]] && cp "$p" "$BACKUP_DIR/" 2>/dev/null
    done
    BACKED_UP=1
    echo "Backups saved to: $BACKUP_DIR"
}

safari_quit_check() {
    if pgrep -xq Safari; then
        echo "$(warn 'Safari is running') — settings written while it runs may be overwritten on quit."
        if confirm "Quit Safari now?"; then
            osascript -e 'tell application "Safari" to quit' 2>/dev/null
            sleep 2
        fi
    fi
}

# ---------------------------------------------------------------------------
# Item status checks — echo "hardened", "NOT hardened", or a detail string
# ---------------------------------------------------------------------------
status_1() {  # OS analytics
    local a t; a=$(dread "$DMH" AutoSubmit); t=$(dread "$DMH" ThirdPartyDataSubmit)
    if [[ "$a" == "1" || "$t" == "1" ]]; then echo "NOT hardened"; else echo "hardened"; fi
}
status_2() {  # Siri data sharing: 2 = opted in, 1 = opted out
    local v; v=$(dread com.apple.assistant.support "Siri Data Sharing Opt-In Status")
    if [[ "$v" == "2" ]]; then echo "NOT hardened"; else echo "hardened"; fi
}
status_3() {  # Personalized ads: absent defaults to ON
    local v; v=$(dread com.apple.AdLib allowApplePersonalizedAdvertising)
    if [[ "$v" == "0" ]]; then echo "hardened"; else echo "NOT hardened"; fi
}
status_4() {  # Safari search telemetry
    local u s; u=$(dread "$SAFARI" UniversalSearchEnabled); s=$(dread "$SAFARI" SuppressSearchSuggestions)
    if [[ "$u" == "0" && "$s" == "1" ]]; then echo "hardened"; else echo "NOT hardened"; fi
}
status_5() {  # Safari tracking protections
    local p e; p=$(dread "$SAFARI" WebKitPreferences.privateClickMeasurementEnabled)
    e=$(dread "$SAFARI" EnableEnhancedPrivacyInRegularBrowsing)
    if [[ "$p" == "0" && "$e" == "1" ]]; then echo "hardened"; else echo "NOT hardened"; fi
}
status_6() {  # Fraudulent-site warning — informational, ON is the default
    local v; v=$(dread "$SAFARI" WarnAboutFraudulentWebsites)
    if [[ "$v" == "0" ]]; then echo "disabled (more private, less safe)"; else echo "enabled (default)"; fi
}

# ---------------------------------------------------------------------------
# Hardening actions
# ---------------------------------------------------------------------------
harden_1() {
    echo "Disabling system-wide diagnostics submission (requires sudo)..."
    backup_plists
    sudo defaults write "$DMH" AutoSubmit            -bool false && \
    sudo defaults write "$DMH" ThirdPartyDataSubmit  -bool false && \
    sudo defaults write "$DMH" SeedAutoSubmit        -bool false && \
    defaults write com.apple.SubmitDiagInfo AutoSubmit -bool false && \
    echo "$(ok 'Done'): Mac Analytics, third-party crash sharing, and seed auto-submit disabled." || \
    echo "$(bad 'Failed') — sudo declined or plist not writable."
}
harden_2() {
    echo "Opting out of Improve Siri & Dictation..."
    backup_plists
    defaults write com.apple.assistant.support "Siri Data Sharing Opt-In Status" -int 1 && \
    echo "$(ok 'Done'): opted out of Siri/Dictation audio sharing." || echo "$(bad 'Failed')"
}
harden_3() {
    echo "Disabling Apple personalized advertising..."
    backup_plists
    defaults write com.apple.AdLib allowApplePersonalizedAdvertising -bool false && \
    defaults write com.apple.AdLib forceLimitAdTracking -bool true && \
    echo "$(ok 'Done'): personalized ads off, Limit Ad Tracking forced." || echo "$(bad 'Failed')"
}
# safari_post_write <key> <expected> — verify a representative key stuck, and
# warn about cfprefsd caching when writing the container plist by file path.
safari_post_write() {
    if [[ "$(dread "$SAFARI" "$1")" == "$2" ]]; then
        echo "$(ok 'Verified'): settings written. Restart Safari to take effect."
        [[ "$SAFARI" != "com.apple.Safari" ]] && \
            echo "$(warn 'Note:') if a setting later reverts, run 'killall cfprefsd' (its cache can overwrite direct plist writes)."
    else
        echo "$(bad 'Warning'): re-read did not return the expected value — settings may not have stuck."
    fi
    [[ "$SAFARI" == "com.apple.Safari" ]] && \
        echo "$(warn 'Note:') no Full Disk Access — verify in Safari settings that these stuck."
}
harden_4() {
    echo "Disabling Safari search & suggestions telemetry..."
    backup_plists
    safari_quit_check
    defaults write "$SAFARI" UniversalSearchEnabled        -bool false && \
    defaults write "$SAFARI" SuppressSearchSuggestions     -bool true  && \
    defaults write "$SAFARI" WebsiteSpecificSearchEnabled  -bool false && \
    defaults write "$SAFARI" PreloadTopHit                 -bool false || \
        { echo "$(bad 'Failed'): could not write Safari preferences."; return 1; }
    echo "Safari Suggestions, search suggestions, Quick Website Search, and Top Hit preloading disabled."
    safari_post_write UniversalSearchEnabled 0
}
harden_5() {
    echo "Enabling Safari tracking protections / disabling ad measurement..."
    backup_plists
    safari_quit_check
    defaults write "$SAFARI" WebKitPreferences.privateClickMeasurementEnabled -bool false && \
    defaults write "$SAFARI" EnableEnhancedPrivacyInRegularBrowsing -bool true && \
    defaults write "$SAFARI" EnableEnhancedPrivacyInPrivateBrowsing -bool true && \
    defaults write "$SAFARI" BlockStoragePolicy -int 2 && \
    defaults write "$SAFARI" WebKitStorageBlockingPolicy -int 1 || \
        { echo "$(bad 'Failed'): could not write Safari preferences."; return 1; }
    echo "Private Click Measurement off, advanced tracking & fingerprinting protection"
    echo "on (all browsing), third-party storage blocked."
    safari_post_write EnableEnhancedPrivacyInRegularBrowsing 1
}
harden_6() {
    echo "Fraudulent-site warning checks URLs against Google Safe Browsing (Tencent in"
    echo "some regions). Disabling stops that lookup traffic but REMOVES phishing protection."
    if confirm "Disable fraudulent-site warning anyway?"; then
        backup_plists
        safari_quit_check
        defaults write "$SAFARI" WarnAboutFraudulentWebsites -bool false && \
        echo "$(ok 'Done'): fraudulent-site warning disabled." || \
        echo "$(bad 'Failed'): could not write Safari preferences."
    else
        echo "Left unchanged."
    fi
}

harden_all() {
    echo
    echo "This will apply items 1-5 (item 6, Safe Browsing, is a security tradeoff"
    echo "and is only available individually)."
    confirm "Proceed?" || { echo "Aborted."; return; }
    harden_1; echo; harden_2; echo; harden_3; echo; harden_4; echo; harden_5
}

# ---------------------------------------------------------------------------
# Full read-only enumeration (the original report)
# ---------------------------------------------------------------------------
show_status() {
    printf '%smacOS Telemetry Configuration Enumeration%s\n' "$BOLD" "$RESET"
    printf 'Host:      %s\n' "$(scutil --get ComputerName 2>/dev/null || hostname)"
    printf 'macOS:     %s (build %s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
    printf 'User:      %s\n' "$(whoami)"
    printf 'Safari:    %s\n' "$SAFARI_MODE"

    section "OS Diagnostics & Usage (Share Mac Analytics)"
    print_key "$DMH" AutoSubmit           "Share Mac Analytics with Apple"
    print_key "$DMH" ThirdPartyDataSubmit "Share crash data with app developers"
    print_key "$DMH" SeedAutoSubmit       "Seed/beta program auto-submit"
    print_key com.apple.SubmitDiagInfo AutoSubmit "SubmitDiagInfo AutoSubmit (per-user)"

    section "Analytics Daemons (launchd status)"
    local svc state
    for svc in com.apple.analyticsd com.apple.SubmitDiagInfo com.apple.osanalytics.osanalyticshelper; do
        if launchctl print "system/$svc" &>/dev/null; then
            state=$(launchctl print "system/$svc" 2>/dev/null | awk -F'= ' '/state =/ {print $2; exit}')
            printf '%-55s %s\n' "$svc:" "${state:-loaded}"
        else
            printf '%-55s %s\n' "$svc:" "not loaded / not visible without root"
        fi
    done

    section "Siri & Dictation Data Sharing"
    local v; v=$(dread com.apple.assistant.support "Siri Data Sharing Opt-In Status")
    case "$v" in
        2) printf '%-55s %s\n' "Improve Siri & Dictation:" "$(bad 'OPTED IN (audio shared with Apple)')" ;;
        1) printf '%-55s %s\n' "Improve Siri & Dictation:" "$(ok 'opted out')" ;;
        *) printf '%-55s %s\n' "Improve Siri & Dictation:" "<not set / never prompted>" ;;
    esac
    print_key com.apple.assistant.support "Assistant Enabled" "Siri enabled"

    section "Apple Personalized Advertising"
    v=$(dread com.apple.AdLib allowApplePersonalizedAdvertising)
    if [[ "$v" == "0" ]]; then
        printf '%-55s %s\n' "Personalized Ads (App Store/News/Stocks):" "$(ok 'disabled')"
    else
        printf '%-55s %s\n' "Personalized Ads (App Store/News/Stocks):" "$(bad "${v/unset/<not set — defaults to ON>}")"
    fi
    print_key com.apple.AdLib forceLimitAdTracking "Force Limit Ad Tracking"

    section "Safari — Search & Suggestions Telemetry"
    print_key "$SAFARI" UniversalSearchEnabled       "Safari Suggestions (sends queries to Apple)"
    print_key "$SAFARI" SuppressSearchSuggestions    "Suppress search-engine suggestions"
    print_key "$SAFARI" WebsiteSpecificSearchEnabled "Quick Website Search"
    print_key "$SAFARI" PreloadTopHit                "Preload Top Hit in background"
    print_key "$SAFARI" SearchProviderShortName      "Default search engine"

    section "Safari — Privacy & Tracking Settings"
    print_key "$SAFARI" WebKitPreferences.privateClickMeasurementEnabled "Private Click Measurement (ad attribution)"
    print_key "$SAFARI" BlockStoragePolicy           "Block storage policy (2 = block 3rd-party)"
    print_key "$SAFARI" EnableEnhancedPrivacyInRegularBrowsing "Adv. tracking/fingerprint protection (normal)"
    print_key "$SAFARI" EnableEnhancedPrivacyInPrivateBrowsing "Adv. tracking/fingerprint protection (private)"
    print_key "$SAFARI" WarnAboutFraudulentWebsites  "Fraudulent-site warning (Safe Browsing)"

    section "MDM / Configuration Profiles"
    if profiles list &>/dev/null; then
        profiles list 2>/dev/null | sed 's/^/  /'
    else
        echo "  'profiles list' failed — run 'sudo profiles show' for full output"
    fi
    echo
}

# ---------------------------------------------------------------------------
# View all settings — every key this tool reads/writes: current vs recommended
# ---------------------------------------------------------------------------
# row <domain> <key> <recommended> <description>
row() {
    local cur mark; cur=$(dread "$1" "$2")
    if [[ "$cur" == "$3" ]]; then
        mark=$(ok '  ok   ')
    elif [[ "$cur" == "unset" ]]; then
        cur="-" ; mark=$(warn ' unset ')
    else
        mark=$(bad 'differs')
    fi
    printf '  %s  %-48s %-9s %-11s %s\n' "$mark" "$2" "$cur" "$3" "$4"
}

view_all() {
    printf '\n%sAll managed settings — current vs recommended%s\n' "$BOLD" "$RESET"
    printf '  %-7s %-48s %-9s %-11s %s\n' "state" "key" "current" "recommended" "description"
    printf '  '; printf -- '-%.0s' {1..108}; echo

    echo "${BOLD}[1] System: $DMH (+ com.apple.SubmitDiagInfo)${RESET}"
    row "$DMH" AutoSubmit           0 "Share Mac Analytics with Apple"
    row "$DMH" ThirdPartyDataSubmit 0 "Share crash data with app developers"
    row "$DMH" SeedAutoSubmit       0 "Seed/beta program auto-submit"
    row com.apple.SubmitDiagInfo AutoSubmit 0 "Per-user diagnostics auto-submit"

    echo "${BOLD}[2] com.apple.assistant.support${RESET}"
    row com.apple.assistant.support "Siri Data Sharing Opt-In Status" 1 "Improve Siri & Dictation (2=opted in)"

    echo "${BOLD}[3] com.apple.AdLib${RESET}"
    row com.apple.AdLib allowApplePersonalizedAdvertising 0 "Apple personalized ads"
    row com.apple.AdLib forceLimitAdTracking              1 "Force Limit Ad Tracking"

    echo "${BOLD}[4] Safari — search & suggestions ($SAFARI_MODE)${RESET}"
    row "$SAFARI" UniversalSearchEnabled       0 "Safari Suggestions (queries to Apple)"
    row "$SAFARI" SuppressSearchSuggestions    1 "Suppress search-engine suggestions"
    row "$SAFARI" WebsiteSpecificSearchEnabled 0 "Quick Website Search"
    row "$SAFARI" PreloadTopHit                0 "Preload Top Hit in background"

    echo "${BOLD}[5] Safari — tracking protections${RESET}"
    row "$SAFARI" WebKitPreferences.privateClickMeasurementEnabled 0 "Private Click Measurement"
    row "$SAFARI" EnableEnhancedPrivacyInRegularBrowsing 1 "Adv. fingerprint protection (normal)"
    row "$SAFARI" EnableEnhancedPrivacyInPrivateBrowsing 1 "Adv. fingerprint protection (private)"
    row "$SAFARI" BlockStoragePolicy           2 "Block third-party storage"
    row "$SAFARI" WebKitStorageBlockingPolicy  1 "WebKit storage blocking"

    echo "${BOLD}[6] Safari — security tradeoff (recommended value = keep default ON)${RESET}"
    row "$SAFARI" WarnAboutFraudulentWebsites  1 "Fraudulent-site warning (Safe Browsing)"

    printf '\n  %s = matches recommendation   %s = differs   %s = not set (OS default applies)\n' \
        "$(ok 'ok')" "$(bad 'differs')" "$(warn 'unset')"
    echo "  Note: for several keys 'unset' means the telemetry-on default applies — harden to pin them."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
colour_status() {  # colour-code a status string from status_N
    case "$1" in
        hardened)      ok "hardened" ;;
        "NOT hardened") bad "NOT hardened" ;;
        *)             warn "$1" ;;
    esac
}

menu() {
    while true; do
        printf '\n%s=== macOS Telemetry Hardening ===%s  (Safari via %s)\n\n' "$BOLD" "$RESET" "$SAFARI_MODE"
        printf '  1) OS analytics & crash-data sharing ............ %s\n' "$(colour_status "$(status_1)")"
        printf '  2) Improve Siri & Dictation opt-out ............. %s\n' "$(colour_status "$(status_2)")"
        printf '  3) Apple personalized advertising ............... %s\n' "$(colour_status "$(status_3)")"
        printf '  4) Safari search & suggestions telemetry ........ %s\n' "$(colour_status "$(status_4)")"
        printf '  5) Safari tracking protections & ad measurement . %s\n' "$(colour_status "$(status_5)")"
        printf '  6) Safari fraudulent-site warning (tradeoff) .... %s\n' "$(colour_status "$(status_6)")"
        printf '\n  a) Harden ALL (1-5)    v) View all settings    s) Full status report    q) Quit\n\n'
        local choice
        read -r -p "Select item to harden [1-6/a/v/s/q]: " choice || { echo; break; }
        echo
        case "$choice" in
            1) harden_1 ;;
            2) harden_2 ;;
            3) harden_3 ;;
            4) harden_4 ;;
            5) harden_5 ;;
            6) harden_6 ;;
            a|A) harden_all ;;
            v|V) view_all ;;
            s|S) show_status ;;
            q|Q) echo "Bye."; break ;;
            *) echo "Unknown option: $choice" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --status)     show_status ;;
    --view)       view_all ;;
    --harden-all) harden_all ;;
    "")           if [[ -t 0 ]]; then menu; else show_status; fi ;;
    *)            echo "Usage: $0 [--status | --view | --harden-all]"; exit 1 ;;
esac
