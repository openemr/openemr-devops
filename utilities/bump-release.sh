#!/bin/bash
# usage: bump-release.sh [--dry-run] [--copy] OLD_VERSION NEW_VERSION [OLD_SHORT NEW_SHORT]
#
# Move mode (default) - use when old version will never be released:
#   ./bump-release.sh 8.0.1 8.1.0 801 810
#
# Copy mode - use when old version still needs to exist alongside new:
#   ./bump-release.sh --copy 8.1.0 8.1.1 810 811
#
# Dry run either mode:
#   ./bump-release.sh --dry-run 8.0.1 8.1.0 801 810
#   ./bump-release.sh --dry-run --copy 8.1.0 8.1.1 810 811

DRY_RUN=false
COPY_MODE=false

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true; shift ;;
        --copy)    COPY_MODE=true; shift ;;
        *)         ;;
    esac
done

OLD=${1:?Usage: $0 [--dry-run] [--copy] OLD_VERSION NEW_VERSION [OLD_SHORT NEW_SHORT]}
NEW=${2:?Usage: $0 [--dry-run] [--copy] OLD_VERSION NEW_VERSION [OLD_SHORT NEW_SHORT]}
OLD_SHORT="${3:-}"
NEW_SHORT="${4:-}"

DRY="[DRY RUN] "
if ${DRY_RUN}; then
    echo "*** DRY RUN MODE - no changes will be made ***"
    echo ""
fi

if ${COPY_MODE}; then
    echo "*** COPY MODE - old directories will be preserved ***"
    echo ""
else
    echo "*** MOVE MODE - old directories will be removed ***"
    echo ""
fi

show_matches() {
    local file="${1}"
    local search="${2}"
    local replace="${3}"
    while IFS= read -r line; do
        lineno="${line%%:*}"
        content="${line#*:}"
        new_content="${content//${search}/${replace}}"
        echo "    line ${lineno}:"
        echo "      was: ${content}"
        echo "      now: ${new_content}"
    done < <(grep -n "${search}" "${file}" || true)
}

# --- Pass 1: Move or copy version-named directories ---
echo "Searching for directories named with version ${OLD} ..."
dirs=$(find . -type d -name "*${OLD}*" -not -path "*/obsolete/*")

if [[ -n "${dirs}" ]]; then
    echo "Found:"
    echo "${dirs}"
    echo ""

    if ! ${DRY_RUN}; then
        if ${COPY_MODE}; then
            echo "Will COPY directories and update contents ${OLD} -> ${NEW}. Hit any key to continue, ctrl-c to abort."
        else
            echo "Will MOVE directories and update contents ${OLD} -> ${NEW}. Hit any key to continue, ctrl-c to abort."
        fi
        read -r _ans
    fi

    for old_dir in ${dirs}; do
        new_dir="${old_dir//${OLD}/${NEW}}"
        if ${COPY_MODE}; then
            echo "${DRY_RUN:+${DRY}}Copy directory: ${old_dir} -> ${new_dir}"
        else
            echo "${DRY_RUN:+${DRY}}Move directory: ${old_dir} -> ${new_dir}"
        fi

        while IFS= read -r f; do
            new_f="${f//${OLD}/${NEW}}"
            echo "  ${DRY_RUN:+${DRY}}Rename file: ${f} -> ${new_f}"
        done < <(find "${old_dir}" -depth -name "*${OLD}*" || true)

        while IFS= read -r f; do
            file_type=$(file "${f}")
            if echo "${file_type}" | grep -q text; then
                if grep -q "${OLD}" "${f}"; then
                    new_f="${f//${OLD}/${NEW}}"
                    echo "  ${DRY_RUN:+${DRY}}Update contents: ${f} -> ${new_f}"
                    show_matches "${f}" "${OLD}" "${NEW}"
                fi
            fi
        done < <(find "${old_dir}" -type f || true)

        if ! ${DRY_RUN}; then
            if ${COPY_MODE}; then
                if [[ -e "${new_dir}" ]]; then
                    echo "  [SKIPPED] ${new_dir} already exists - will not overwrite"
                    continue
                fi
                cp -r "${old_dir}" "${new_dir}"
            else
                mv "${old_dir}" "${new_dir}"
            fi

            while IFS= read -r f; do
                new_f="${f//${OLD}/${NEW}}"
                mv "${f}" "${new_f}"
            done < <(find "${new_dir}" -depth -name "*${OLD}*" || true)

            while IFS= read -r f; do
                file_type=$(file "${f}")
                if echo "${file_type}" | grep -q text; then
                    if grep -q "${OLD}" "${f}"; then
                        sed -i "s/${OLD}/${NEW}/g" "${f}"
                    fi
                fi
            done < <(find "${new_dir}" -type f || true)
        fi
    done
else
    echo "No directories found matching ${OLD}"
fi

# --- Pass 1b: Rename or copy individual files matching OLD_SHORT outside versioned dirs ---
if [[ -n "${OLD_SHORT}" ]]; then
    echo ""
    echo "Searching for files named with short version ${OLD_SHORT} ..."
    short_files=$(find . -type f -name "*${OLD_SHORT}*" \
        -not -path "*/obsolete/*" \
        -not -path "*/.git/*" \
        -not -name "$(basename "$0")")

    if [[ -n "${short_files}" ]]; then
        while IFS= read -r f; do
            new_f="${f//${OLD_SHORT}/${NEW_SHORT}}"
            if ${COPY_MODE}; then
                if [[ -e "${new_f}" ]]; then
                    echo "  [SKIPPED] ${new_f} already exists - will not overwrite"
                else
                    echo "  ${DRY_RUN:+${DRY}}Copy file: ${f} -> ${new_f}"
                    if ! ${DRY_RUN}; then
                        cp "${f}" "${new_f}"
                    fi
                fi
            else
                echo "  ${DRY_RUN:+${DRY}}Rename file: ${f} -> ${new_f}"
                if ! ${DRY_RUN}; then
                    mv "${f}" "${new_f}"
                fi
            fi
        done < <(echo "${short_files}")
    else
        echo "No files found matching ${OLD_SHORT}"
    fi
fi

# --- Pass 2: Find all remaining references across the whole repo ---
if ! ${COPY_MODE}; then
    echo ""
    echo "Scanning all files in repo for remaining references to ${OLD} ..."
    matches=$(grep -rl "${OLD}" . \
        --exclude-dir=".git" \
        --exclude-dir="obsolete" \
        --exclude="$(basename "$0")" \
        --exclude="demo_5_0_0_5.sql")

    if [[ -z "${matches}" ]]; then
        echo "No remaining references found."
    else
        echo ""
        while IFS= read -r f; do
            file_type=$(file "${f}")
            if echo "${file_type}" | grep -q text; then
                echo "  ${DRY_RUN:+${DRY}}Update contents: ${f}"
                show_matches "${f}" "${OLD}" "${NEW}"
            fi
        done < <(echo "${matches}")
        echo ""

        if ! ${DRY_RUN}; then
            echo "Will update all references ${OLD} -> ${NEW} in the files above. Hit any key to continue, ctrl-c to abort."
            read -r _ans

            while IFS= read -r f; do
                file_type=$(file "${f}")
                if echo "${file_type}" | grep -q text; then
                    echo "  Updating: ${f}"
                    sed -i "s/${OLD}/${NEW}/g" "${f}"
                fi
            done < <(echo "${matches}")
        fi
    fi
fi

# --- Pass 2b: Find remaining references to OLD_SHORT if provided ---
if [[ -n "${OLD_SHORT}" ]] && ! ${COPY_MODE}; then
    echo ""
    echo "Scanning all files in repo for remaining references to ${OLD_SHORT} ..."
    short_matches=$(grep -rl "${OLD_SHORT}" . \
        --exclude-dir=".git" \
        --exclude-dir=".idea" \
        --exclude-dir="obsolete" \
        --exclude="$(basename "$0")" \
        --exclude="demo_5_0_0_5.sql")

    if [[ -z "${short_matches}" ]]; then
        echo "No remaining references to ${OLD_SHORT} found."
    else
        echo ""
        while IFS= read -r f; do
            file_type=$(file "${f}")
            if echo "${file_type}" | grep -q text; then
                echo "  ${DRY_RUN:+${DRY}}Update contents: ${f}"
                show_matches "${f}" "${OLD_SHORT}" "${NEW_SHORT}"
            fi
        done < <(echo "${short_matches}")
        echo ""

        if ! ${DRY_RUN}; then
            echo "Will update all references ${OLD_SHORT} -> ${NEW_SHORT} in the files above. Hit any key to continue, ctrl-c to abort."
            read -r _ans

            while IFS= read -r f; do
                file_type=$(file "${f}")
                if echo "${file_type}" | grep -q text; then
                    echo "  Updating: ${f}"
                    sed -i "s/${OLD_SHORT}/${NEW_SHORT}/g" "${f}"
                fi
            done < <(echo "${short_matches}")
        fi
    fi
fi

echo ""
if ${DRY_RUN}; then
    echo "*** Dry run complete - no changes were made ***"
    echo "Re-run without --dry-run to apply."
else
    echo "Done. Review with: git diff"
fi

# --- Final notes ---
echo ""
if [[ -z "${OLD_SHORT}" ]]; then
    echo "NOTE: Files with dotless version names (e.g. build-801.yml) were NOT renamed."
    echo "      Re-run with short version args to handle these:"
    echo "      $0 [--dry-run] [--copy] ${OLD} ${NEW} 801 810"
fi
if ${COPY_MODE}; then
    echo "NOTE: build-${NEW_SHORT}.yml was copied from build-${OLD_SHORT}.yml."
    echo "      Review and update branch refs and tags before committing."
fi
