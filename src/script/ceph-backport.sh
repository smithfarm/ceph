#!/bin/bash -e
#
# ceph-backport.sh - Ceph backporting script
#
# Credits: This script is based on work done by Loic Dachary
#
#
# This script automates the process of staging a backport starting from a
# Backport tracker issue.
#
# Setup:
#
#     ceph-backport.sh --setup
#     ceph-backport.sh --setup-report
#
# Usage and troubleshooting:
#
#     ceph-backport.sh --help
#     ceph-backport.sh --usage
#     ceph-backport.sh --troubleshooting
#
#

SCRIPT_VERSION="15.0.0.6270"
full_path="$0"
this_script=$(basename "$full_path")
deprecated_backport_common="$HOME/bin/backport_common.sh"

if [[ $* == *--debug* ]]; then
    set -x
fi

# associative array keyed on "component" strings from PR titles, mapping them to
# GitHub PR labels that make sense in backports
declare -A comp_hash=(
["bluestore"]="bluestore"
["build/ops"]="build/ops"
["ceph.spec"]="build/ops"
["ceph-volume"]="ceph-volume"
["cephfs"]="cephfs"
["cmake"]="build/ops"
["config"]="config"
["client"]="cephfs"
["common"]="common"
["core"]="core"
["dashboard"]="dashboard"
["deb"]="build/ops"
["doc"]="documentation"
["grafana"]="monitoring"
["mds"]="cephfs"
["messenger"]="core"
["mon"]="core"
["msg"]="core"
["mgr/dashboard"]="dashboard"
["mgr/prometheus"]="monitoring"
["mgr"]="core"
["monitoring"]="monitoring"
["orch"]="orchestrator"
["osd"]="core"
["perf"]="performance"
["prometheus"]="monitoring"
["pybind"]="pybind"
["py3"]="python3"
["python3"]="python3"
["qa"]="tests"
["rbd"]="rbd"
["rgw"]="rgw"
["rpm"]="build/ops"
["tests"]="tests"
["tool"]="tools"
)

declare -A flagged_pr_hash=()

function abort_due_to_setup_problem {
    error "Problem detected in your setup"
    echo -en "Run \"${this_script} --setup\" to fix"
    if [ "$SETUP_REPORT" ] ; then
        echo -en "\n"
    else
        echo -en ", or --setup-report for a summary\n"
    fi
    false
}

function assert_fail {
    local message="$1"
    error "(internal error) $message"
    info "This could be reported as a bug!"
    false
}

function bail_out_github_api {
    local api_said="$1"
    info "GitHub API said:"
    log bare "$api_said"
    info "(hint) check the value of github_token"
    abort_due_to_setup_problem
}

function blindly_set_pr_metadata {
    local pr_number="$1"
    local json_blob="$2"
    curl --silent --data-binary "$json_blob" "https://api.github.com/repos/ceph/ceph/issues/${pr_number}?access_token=${github_token}" >/dev/null 2>&1 || true
}

function check_milestones {
    local milestones_to_check
    milestones_to_check="$(echo "$1" | tr '\n' ' ' | xargs)"
    info "Active milestones: $milestones_to_check"
    for m in $milestones_to_check ; do
        info "Examining all PRs targeting base branch \"$m\""
        vet_prs_for_milestone "$m"
    done
    dump_flagged_prs
}

function check_tracker_status {
    local -a ok_statuses=("new" "need more info")
    local ts="$1"
    local error_msg
    local tslc="${ts,,}"
    local tslc_is_ok=
    for oks in "${ok_statuses[@]}"; do
        if [ "$tslc" = "$oks" ] ; then
            debug "Tracker status $ts is OK for backport to proceed"
            tslc_is_ok="yes"
            break
        fi
    done
    if [ "$tslc_is_ok" ] ; then
        true
    else
        if [ "$tslc" = "in progress" ] ; then
            error_msg="backport $redmine_url is already in progress"
        else
            error_msg="backport $redmine_url is closed (status: ${ts})"
        fi
        if [ "$FORCE" ] ; then
            warning "$error_msg"
        else
            error "$error_msg"
        fi
    fi
    echo "$tslc_is_ok"
}

function cherry_pick_phase {
    local base_branch
    local i
    local merged
    local number_of_commits
    local offset
    local singular_or_plural_commit
    populate_original_issue
    if [ -z "$original_issue" ] ; then
        error "Could not find original issue"
        info "Does ${redmine_url} have a \"Copied from\" relation?"
        false
    fi
    info "Parent issue: ${redmine_endpoint}/issues/${original_issue}"

    populate_original_pr
    if [ -z "$original_pr" ]; then
        error "Could not find original PR"
        info "Is the \"Pull request ID\" field of ${redmine_endpoint}/issues/${original_issue} populated?"
        false
    fi
    info "Parent issue ostensibly fixed by: ${original_pr_url}"

    verbose "Examining ${original_pr_url}"
    remote_api_output=$(curl --silent "https://api.github.com/repos/ceph/ceph/pulls/${original_pr}?access_token=${github_token}")
    base_branch=$(echo "${remote_api_output}" | jq -r '.base.label')
    if [ "$base_branch" = "ceph:master" ] ; then
        true
    else
        error "${original_pr_url} is targeting ${base_branch}: cowardly refusing to perform automated cherry-pick"
        info "Out of an abundance of caution, the script only automates cherry-picking of commits from PRs targeting \"ceph:master\"."
        info "You can still use the script to stage the backport, though. Just prepare the local branch \"${local_branch}\" manually and re-run the script."
        false
    fi
    merged=$(echo "${remote_api_output}" | jq -r '.merged')
    if [ "$merged" = "true" ] ; then
        true
    else
        error "${original_pr_url} is not merged yet"
        info "Cowardly refusing to perform automated cherry-pick"
        false
    fi
    number_of_commits=$(echo "${remote_api_output}" | jq '.commits')
    if [ "$number_of_commits" -eq "$number_of_commits" ] 2>/dev/null ; then
        # \$number_of_commits is set, and is an integer
        if [ "$number_of_commits" -eq "1" ] ; then
            singular_or_plural_commit="commit"
        else
            singular_or_plural_commit="commits"
        fi
    else
        error "Could not determine the number of commits in ${original_pr_url}"
        bail_out_github_api "$remote_api_output"
    fi
    info "Found $number_of_commits $singular_or_plural_commit in $original_pr_url"

    debug "Fetching latest commits from $upstream_remote"
    git fetch "$upstream_remote"

    debug "Initializing local branch $local_branch to $milestone"
    if git show-ref --verify --quiet "refs/heads/$local_branch" ; then
        if [ "$FORCE" ] ; then
            warning "refs/heads/$local_branch already exists"
            info "--force was given, so clobbering it"
            git checkout "$local_branch"
            git reset --hard "${upstream_remote}/${milestone}"
        else
            error "Cannot initialize $local_branch - local branch already exists"
            false
        fi
    else
        git checkout "${upstream_remote}/${milestone}" -b "$local_branch"
    fi

    debug "Fetching latest commits from ${original_pr_url}"
    git fetch "$upstream_remote" "pull/$original_pr/head:pr-$original_pr"

    info "Attempting to cherry pick $number_of_commits commits from ${original_pr_url} into local branch $local_branch"
    offset="$((number_of_commits - 1))" || true
    for ((i=offset; i>=0; i--)) ; do
        debug "Cherry-picking commit $(git log --oneline --max-count=1 --no-decorate "pr-${original_pr}~${i}")"
        if git cherry-pick -x "pr-${original_pr}~${i}" ; then
            true
        else
            [ "$VERBOSE" ] && git status
            error "Cherry pick failed"
            info "Next, manually fix conflicts and complete the current cherry-pick"
            if [ "$i" -gt "0" ] >/dev/null 2>&1 ; then
                info "Then, cherry-pick the remaining commits from ${original_pr_url}, i.e.:"
                for ((j=i-1; j>=0; j--)) ; do
                    info "-> missing commit: $(git log --oneline --max-count=1 --no-decorate "pr-${original_pr}~${j}")"
                done
                info "Finally, re-run the script"
            else
                info "Then re-run the script"
            fi
            false
        fi
    done
    info "Cherry picking completed without conflicts"
}

function clear_line {
    log overwrite "                                                                             \r"
}

function debug {
    log debug "$@"
}

function display_version_message_and_exit {
    echo "$this_script: Ceph backporting script, version $SCRIPT_VERSION"
    exit 0 
}

function dump_flagged_prs {
    local url=
    clear_line
    if [ "${#flagged_pr_hash[@]}" -eq "0" ] ; then
        info "All backport PRs appear to have milestone set correctly"
    else
        warning "Some backport PRs had problematic milestone settings"
        log bare "==========="
        log bare "Flagged PRs"
        log bare "==========="
        for url in "${!flagged_pr_hash[@]}" ; do
            log bare "$url - ${flagged_pr_hash[$url]}"
        done
        log bare "==========="
    fi
}

function eol {
    local mtt="$1"
    error "$mtt is EOL"
    false
}

function error {
    log error "$@"
}

function failed_mandatory_var_check {
    local varname="$1"
    local error="$2"
    error "$varname $error"
    setup_ok=""
    setup_state="NOT OK"
}

function flag_pr {
    local pr_num="$1"
    local pr_url="$2"
    local flag_reason="$3"
    warning "flagging PR#${pr_num} because $flag_reason"
    flagged_pr_hash["${pr_url}"]="$flag_reason"
}

function from_file {
    local what="$1"
    xargs 2>/dev/null < "$HOME/.${what}" || true
}

function get_user_input {
    local default_val="$1"
    local user_input=
    read -r user_input
    if [ "$user_input" ] ; then
        echo "$user_input"
    else
        echo "$default_val"
    fi
}

# takes a string and a substring - returns position of substring within string,
# or -1 if not found
# NOTE: position of first character in string is 0
function grep_for_substr {
    munged="${1%%$2*}"
    if [ "$munged" = "$1" ] ; then
        echo "-1"
    else
        echo "${#munged}"
    fi
}

# takes PR title, attempts to guess component
function guess_component {
    local comp=
    local pos="0"
    local pr_title="$1"
    local winning_comp=
    local winning_comp_pos="9999"
    for comp in "${!comp_hash[@]}" ; do
        pos=$(grep_for_substr "$pr_title" "$comp")
        # echo "$comp: $pos"
        [ "$pos" = "-1" ] && continue
        if [ "$pos" -lt "$winning_comp_pos" ] ; then
             winning_comp_pos="$pos"
             winning_comp="$comp"
        fi
    done
    [ "$winning_comp" ] && echo "${comp_hash["$winning_comp"]}" || echo ""
}

function info {
    log info "$@"
}

function init_endpoints {
    verbose "Initializing remote API endpoints"
    redmine_endpoint="${redmine_endpoint:-"https://tracker.ceph.com"}"
    github_endpoint="${github_endpoint:-"https://github.com/ceph/ceph"}"
}

function init_fork_remote {
    [ "$github_user" ] || assert_fail "github_user not set"
    fork_remote="${fork_remote:-$(maybe_deduce_remote fork)}"
}

function init_upstream_remote {
    upstream_remote="${upstream_remote:-$(maybe_deduce_remote upstream)}"
}

function interactive_setup_routine {
    VERBOSE="yes"
    source "$deprecated_backport_common" || true
    echo
    echo "Welcome to the ${this_script} interactive setup routine!"
    echo
    echo "---------------------------------------------------------------------"
    echo "Setup step 1 of 4"
    echo "---------------------------------------------------------------------"
    echo -n "What is your GitHub username? "
    default_value="$github_user"
    [ "$github_user" ] && echo -n "(default: ${default_value}) "
    vet_github_user "$(get_user_input "$default_value")"
    echo
    echo "---------------------------------------------------------------------"
    echo "Setup step 2 of 4"
    echo "---------------------------------------------------------------------"
    echo "Searching \"git remote -v\" for remote repos"
    echo
    init_upstream_remote
    init_fork_remote
    vet_remotes
    echo
    echo "---------------------------------------------------------------------"
    echo "Setup step 3 of 4"
    echo "---------------------------------------------------------------------"
    echo "For information on how to generate a GitHub personal access token"
    echo "to use with this script, go to https://github.com/settings/tokens"
    echo "then click on \"Generate new token\" and make sure the token has"
    echo "\"Full control of private repositories\" scope."
    echo
    echo "For more details, see:"
    echo "https://help.github.com/en/articles/creating-a-personal-access-token-for-the-command-line"
    echo
    echo -n "What is your GitHub personal access token? "
    default_value="$github_token"
    [ "$github_token" ] && echo "(default: ${default_value})"
    github_token="$(get_user_input "$default_value")"
    if [ "$github_token" ] ; then
        vet_github_token "$github_token" "$default_value"
    else
        error "You must provide a GitHub token"
        abort_due_to_setup_problem
    fi
    echo
    echo "---------------------------------------------------------------------"
    echo "Setup step 4 of 4"
    echo "---------------------------------------------------------------------"
    echo "To generate a Redmine API access key, go to https://tracker.ceph.com"
    echo "After signing in, click: \"My account\""
    echo "Now, find \"API access key\"."
    echo "Once you know the API access key, enter it below."
    echo
    echo -n "What is your Redmine API access key? "
    default_value="$redmine_key"
    [ "$redmine_key" ] && echo "(default: ${default_value})"
    redmine_key="$(get_user_input "$default_value")"
    if [ "$redmine_key" ] ; then
        vet_redmine_key "$redmine_key"
    else
        error "You must provide a Redmine API access key"
        abort_due_to_setup_problem
    fi
    echo
    vet_setup
    maybe_delete_backport_common
}

function is_active_milestone {
    local is_active=
    local milestone_under_test="$1"
    for m in $active_milestones ; do
        if [ "$milestone_under_test" = "$m" ] ; then
            verbose "Milestone $m is active"
            is_active="yes"
            break
        fi
    done
    echo "$is_active"
}

function log {
    local level="$1"
    local trailing_newline="yes"
    shift
    local msg="$*"
    prefix="${this_script}: "
    verbose_only=
    case $level in
        bare)
            prefix=
            ;;
        debug)
            prefix="${prefix}DEBUG: "
            verbose_only="yes"
            ;;
        err*)
            prefix="${prefix}ERROR: "
            ;;
        info)
            :
            ;;
        overwrite)
            trailing_newline=
            prefix=
            ;;
        verbose)
            verbose_only="yes"
            ;;
        verbose_en)
            verbose_only="yes"
            trailing_newline=
            ;;
        warn|warning)
            prefix="${prefix}WARNING: "
            ;;
    esac
    if [ "$verbose_only" ] && [ -z "$VERBOSE" ] ; then
        true
    else
        msg="${prefix}${msg}"
        if [ "$trailing_newline" ] ; then
            echo "${msg}" >&2
        else
            echo -en "${msg}" >&2
        fi
    fi
}

function maybe_deduce_remote {
    local remote_type="$1"
    local remote=""
    local url_component=""
    if [ "$remote_type" = "upstream" ] ; then
        url_component="ceph"
    elif [ "$remote_type" = "fork" ] ; then
        url_component="$github_user"
    else
        assert_fail "bad remote_type ->$remote_type<- in maybe_deduce_remote"
    fi
    remote=$(git remote -v | grep --extended-regexp --ignore-case '(://|@)github.com(/|:)'${url_component}'/ceph(\s|\.|\/)' | head -n1 | cut -f 1)
    echo "$remote"
}

function maybe_delete_backport_common {
    local default_val
    local user_inp
    local yes_delete_it
    if [ -e "$deprecated_backport_common" ] ; then
        echo "You still have a $deprecated_backport_common file. This file has been"
        echo "deprecated in favor of this interactive setup routine. The contents of"
        echo "that file are:"
        echo
        cat "$deprecated_backport_common"
        echo
        echo "Since this file is deprecated and no longer used, would you like to"
        echo -n "delete it now? (default: no) "
        default_val="no"
        user_inp="$(get_user_input "$default_value")"
        user_inp="$(echo "$user_inp" | tr '[:upper:]' '[:lower:]' | xargs)"
        if [ "$user_inp" ] ; then
            user_inp="${user_inp:0:1}"
            if [ "$user_inp" = "y" ] ; then
                set -x
                rm $deprecated_backport_common
                set +x
            fi
        fi
    fi
}

function milestone_number_from_remote_api {
    local mtt="$1"  # milestone to try
    local mn=""     # milestone number
    local milestones
    warning "Milestone ->$mtt<- unknown to script - falling back to GitHub API"
    remote_api_output=$(curl --silent -X GET "https://api.github.com/repos/ceph/ceph/milestones?access_token=${github_token}")
    mn=$(echo "$remote_api_output" | jq --arg milestone "$mtt" '.[] | select(.title==$milestone) | .number')
    if [ "$mn" -gt "0" ] >/dev/null 2>&1 ; then
        echo "$mn"
    else
        error "Could not determine milestone number of ->$milestone<-"
        verbose_en "GitHub API said:\n${remote_api_output}\n"
        remote_api_output=$(curl --silent -X GET "https://api.github.com/repos/ceph/ceph/milestones?access_token=${github_token}")
        milestones=$(echo "$remote_api_output" | jq '.[].title')
        info "Valid values are ${milestones}"
        info "(This probably means the Release field of ${redmine_url} is populated with"
        info "an unexpected value - i.e. it does not match any of the GitHub milestones.)"
        false
    fi
}

function populate_original_issue {
    if [ -z "$original_issue" ] ; then
        original_issue=$(curl --silent "${redmine_url}.json?include=relations" |
            jq '.issue.relations[] | select(.relation_type | contains("copied_to")) | .issue_id')
    fi
}

function populate_original_pr {
    if [ "$original_issue" ] ; then
        if [ -z "$original_pr" ] ; then
            original_pr=$(curl --silent "${redmine_endpoint}/issues/${original_issue}.json" |
                          jq -r '.issue.custom_fields[] | select(.id | contains(21)) | .value')
            original_pr_url="${github_endpoint}/pull/${original_pr}"
        fi
    fi
}

function tracker_component_is_in_desired_state {
    local comp="$1"
    local val_is="$2"
    local val_should_be="$3"
    local in_desired_state
    if [ "$val_is" = "$val_should_be" ] ; then
        debug "Tracker $comp is in the desired state"
        in_desired_state="yes"
    fi
    echo "$in_desired_state"
}

function tracker_component_was_updated {
    local comp="$1"
    local val_old="$2"
    local val_new="$3"
    local was_updated
    if [ "$val_old" = "$val_new" ] ; then
        true
    else
        debug "Tracker $comp was updated!"
        was_updated="yes"
    fi
    echo "$was_updated"
}

function troubleshooting_advice {
    cat <<EOM
Troubleshooting notes
---------------------

If the script inexplicably fails with:

    error: a cherry-pick or revert is already in progress
    hint: try "git cherry-pick (--continue | --quit | --abort)"
    fatal: cherry-pick failed

This is because HEAD is not where git expects it to be:

    $ git cherry-pick --abort
    warning: You seem to have moved HEAD. Not rewinding, check your HEAD!

This can be fixed by issuing the command:

    $ git cherry-pick --quit

EOM
}

# to update known milestones, consult:
#   curl --verbose -X GET https://api.github.com/repos/ceph/ceph/milestones
function try_known_milestones {
    local mtt=$1  # milestone to try
    local mn=""   # milestone number
    case $mtt in
        cuttlefish) eol "$mtt" ;;
        dumpling) eol "$mtt" ;;
        emperor) eol "$mtt" ;;
        firefly) eol "$mtt" ;;
        giant) eol "$mtt" ;;
        hammer) eol "$mtt" ;;
        infernalis) eol "$mtt" ;;
        jewel) mn="8" ;;
        kraken) eol "$mtt" ;;
        luminous) mn="10" ;;
        mimic) mn="11" ;;
        nautilus) mn="12" ;;
        octopus) echo "Octopus milestone number is unknown! Update the script now." ; exit 1 ;;
    esac
    echo "$mn"
}

function update_version_number_and_exit {
    set -x
    local raw_version
    local munge_first_hyphen
    # munge_first_hyphen will look like this: 15.0.0.5774-g4c2f2eda969
    local script_version_number
    munge_first_hyphen="${raw_version/-/.}"
    raw_version="$(git describe --long --match 'v*' | sed 's/^v//')"  # example: "15.0.0-5774-g4c2f2eda969"
    script_version_number="${munge_first_hyphen%-*}"  # example: "15.0.0.5774"
    sed -i -e "s/^SCRIPT_VERSION=.*/SCRIPT_VERSION=${script_version_number}/" "$full_path"
    exit 0
}

function usage {
    cat <<EOM >&2
Initial setup (interactive):

   ${this_script} --setup

Setup report:

   ${this_script} --setup-report

Documentation:

   ${this_script} --usage | less
   ${this_script} --troubleshooting | less

Usage:
   ${this_script} BACKPORT_TRACKER_ISSUE_NUMBER

Options (not needed in normal operation):
    --cherry-pick-only    (stop after cherry-pick phase)
    --component/-c COMPONENT
                          (explicitly set the component label; if omitted, the
                           script will try to guess the component)
    --debug               (turns on "set -x")
    --existing-pr BACKPORT_PR_ID
                          (use this when the backport PR is already open and
                           you only need to update the Backport tracker issue)
    --milestones          (vet all backport PRs for correct milestone setting)
    --setup/-s            (run the interactive setup routine - NOTE: this can 
                           be done any number of times)
    --setup-report        (check the setup and print a report)
    --update-version      (this option exists as a convenience for the script
                           maintainer only: not intended for day-to-day usage)
    --verbose/-v          (produce more output than normal)
    --version             (display version number and exit)

Example:
   ${this_script} 31459
   (if cherry-pick conflicts are present, finish cherry-picking phase manually
   and then run the script again with the same argument)

CAVEAT: The script must be run from inside a local git clone.
EOM
}

function usage_advice {
    cat <<EOM
Usage advice
------------

Once you have completed --setup, you can run the script with the ID of
a Backport tracker issue. For example, to stage the backport
https://tracker.ceph.com/issues/41502, run:

    ${this_script} 41502

Provided the commits in the corresponding master PR cherry-pick cleanly, the
script will automatically perform all steps required to stage the backport:

Cherry-pick phase:

1. fetching the latest commits from the upstream remote
2. creating a wip branch for the backport
3. figuring out which upstream PR contains the commits to cherry-pick
4. cherry-picking the commits

PR phase:

5. pushing the wip branch to your fork
6. opening the backport PR with compliant title and description describing
   the backport
7. (optionally) setting the milestone and label in the PR
8. updating the Backport tracker issue

When run with --cherry-pick-only, the script will stop after the cherry-pick
phase.

If any of the commits do not cherry-pick cleanly, the script will abort in
step 4. In this case, you can either finish the cherry-picking manually
or abort the cherry-pick. In any case, when and if the local wip branch is
ready (all commits cherry-picked), if you run the script again, like so:

    ${this_script} 41502

the script will detect that the wip branch already exists and skip over
steps 1-4, starting from step 5 ("PR phase"). In other words, if the wip branch
already exists for any reason, the script will assume that the cherry-pick
phase (steps 1-4) is complete.

As this implies, you can do steps 1-4 manually. Provided the wip branch name
is in the format wip-\$TRACKER_ID-\$STABLE_RELEASE (e.g. "wip-41502-mimic"),
the script will detect the wip branch and start from step 5.

For details on all the options the script takes, run:

    ${this_script} --help

For more information on Ceph backporting, see:

    https://github.com/ceph/ceph/tree/master/SubmittingPatches-backports.rst

EOM
}

function verbose {
    log verbose "$@"
}

function verbose_en {
    log verbose_en "$@"
}

function vet_github_token {
    local token_to_vet="$1"
    local default_val="$2"
    local user_of_token=
    #
    # $ curl --silent https://api.github.com/repos/ceph/ceph/pulls/19999?access_token=invalid
    # {
    #   "message": "Bad credentials",
    #   "documentation_url": "https://developer.github.com/v3"
    # }
    #
    remote_api_output=$(curl --silent "https://api.github.com/user?access_token=${token_to_vet}")
    user_of_token=$(echo "${remote_api_output}" | jq -r '.login')
    if [ "$user_of_token" = "$github_user" ] 2>/dev/null ; then
        verbose "GitHub token is OK"
        if [ "$token_to_vet" = "$default_val" ] ; then
            true
        else
            github_token="$token_to_vet"
            echo "$github_token" > "$HOME/.github_token"
            info "Wrote ${github_user}'s GitHub token to $HOME/.github_token"
        fi
    else
        error "GitHub token ${token_to_vet} is invalid and/or does not match GitHub user \"${github_user}\""
        info "(hint) Delete $HOME/.github_token and run \"${this_script} --setup\""
        false
    fi
}

function vet_github_user {
    local user_to_vet="$1"
    local curl_cmd
    local github_login
    curl_cmd="curl --silent https://api.github.com/users/${user_to_vet}"
    remote_api_output="$($curl_cmd)"
    github_login="$(echo "$remote_api_output" | jq -r '.login')"
    if [ "$user_to_vet" = "$github_login" ] ; then
        if [ "$user_to_vet" = "$github_user" ] ; then
            verbose "GitHub user setting is OK"
        else
            github_user="$user_to_vet"
            echo "$github_user" > "$HOME/.github_user"
            info "Wrote \"$github_user\" to file $HOME/.github_user"
        fi
    else
        error "GitHub does not recognize that user"
        info "Dumping the curl command, followed by GitHub's response..."
        echo "$curl_cmd"
        info "and GitHub's response was:"
        echo "$remote_api_output"
        false
    fi
}

function vet_pr_milestone {
    local pr_number="$1"
    local pr_title="$2"
    local pr_url="$3"
    local milestone_stanza="$4"
    local milestone_title_should_be="$5"
    local milestone_number_should_be
    local milestone_number_is=
    local milestone_title_is=
    milestone_number_should_be="$(try_known_milestones "$milestone_title_should_be")"
    log overwrite "Vetting milestone of PR#${pr_number}\r"
    if [ "$milestone_stanza" = "null" ] ; then
        blindly_set_pr_metadata "$pr_number" "{\"milestone\": $milestone_number_should_be}"
        warning "$pr_url: set milestone to \"$milestone_title_should_be\""
        flag_pr "$pr_number" "$pr_url" "milestone not set"
    else
        milestone_title_is=$(echo "$milestone_stanza" | jq -r '.title')
        milestone_number_is=$(echo "$milestone_stanza" | jq -r '.number')
        if [ "$milestone_number_is" -eq "$milestone_number_should_be" ] ; then
            true
        else
            blindly_set_pr_metadata "$pr_number" "{\"milestone\": $milestone_number_should_be}"
            warning "$pr_url: changed milestone from \"$milestone_title_is\" to \"$milestone_title_should_be\""
            flag_pr "$pr_number" "$pr_url" "milestone set to wrong value \"$milestone_title_is\""
        fi
    fi
}

function vet_prs_for_milestone {
    local milestone_title="$1"
    local pages_of_output=
    local pr_number=
    local pr_title=
    local pr_url=
    # determine last page (i.e., total number of pages)
    remote_api_output="$(curl --silent --head "https://api.github.com/repos/ceph/ceph/pulls?base=${milestone_title}\&access_token=${github_token}" | grep -E '^Link' || true)"
    if [ "$remote_api_output" ] ; then
         # Link: <https://api.github.com/repositories/2310495/pulls?base=luminous&access_token=f9b0beb6922e418663396f3ff2ab69467a3268f9&page=2>; rel="next", <https://api.github.com/repositories/2310495/pulls?base=luminous&access_token=f9b0beb6922e418663396f3ff2ab69467a3268f9&page=2>; rel="last"
         # shellcheck disable=SC2001
         pages_of_output="$(echo "$remote_api_output" | sed 's/^.*&page\=\([0-9]\+\)>; rel=\"last\".*$/\1/g')"
    else
         pages_of_output="1"
    fi
    verbose "GitHub has $pages_of_output pages of pull request data for \"base:${milestone_title}\""
    for ((page=1; page<=pages_of_output; page++)) ; do
        verbose "Fetching PRs (page $page of ${pages_of_output})"
        remote_api_output="$(curl --silent -X GET "https://api.github.com/repos/ceph/ceph/pulls?base=${milestone_title}\&access_token=${github_token}\&page=${page}")"
        prs_in_page="$(echo "$remote_api_output" | jq -r '. | length')"
        verbose "Page $page of remote API output contains information on $prs_in_page PRs"
        for ((i=0; i<prs_in_page; i++)) ; do
            pr_number="$(echo "$remote_api_output" | jq -r ".[${i}].number")"
            pr_title="$(echo "$remote_api_output" | jq -r ".[${i}].title")"
            pr_url="${github_endpoint}/pull/${pr_number}"
            milestone_stanza="$(echo "$remote_api_output" | jq -r ".[${i}].milestone")"
            vet_pr_milestone "$pr_number" "$pr_title" "$pr_url" "$milestone_stanza" "$milestone_title"
        done
        clear_line
    done
}

function vet_redmine_key {
    local key_to_vet="$1"
    local default_val="$2"
    local api_key_from_api
    local redmine_user_id_from_file
    remote_api_output="$(curl --silent "https://tracker.ceph.com/users/current.json?key=$key_to_vet")"
    redmine_login="$(echo "$remote_api_output" | jq -r '.user.login')"
    redmine_user_id="$(echo "$remote_api_output" | jq -r '.user.id')"
    api_key_from_api="$(echo "$remote_api_output" | jq -r '.user.api_key')"
    if [ "$redmine_login" ] && [ "$redmine_user_id" ] && [ "$api_key_from_api" = "$key_to_vet" ] ; then
        if [ "$key_to_vet" = "$default_val" ] ; then
            true
        else
            redmine_key="$key_to_vet"
            echo "$redmine_key" > "$HOME/.redmine_key"
            info "Wrote Redmine API access key to $HOME/.redmine_key"
        fi
        redmine_user_id_from_file="$(from_file redmine_user_id)"
        if [ "$redmine_user_id_from_file" = "$redmine_user_id" ] ; then
            true
        else
            echo "$redmine_user_id" > "$HOME/.redmine_user_id"
            info "Wrote Redmine user ID $redmine_user_id to $HOME/.redmine_user_id"
        fi
    else
        error "Redmine API access key $key_to_vet is invalid"
        info "(hint) Delete file $HOME/.redmine_key and run \"${this_script} --setup\""
        false
    fi
}

function vet_remotes {
    if [ "$upstream_remote" ] ; then
        verbose "Upstream remote is $upstream_remote"
    else
        error "Cannot auto-determine upstream remote"
        "(Could not find any upstream remote in \"git remote -v\")"
        false
    fi
    if [ "$fork_remote" ] ; then
        verbose "Fork remote is $fork_remote"
    else
        error "Cannot auto-determine fork remote"
        info "(Could not find GitHub user ${github_user}'s fork of ceph/ceph in \"git remote -v\")"
        false
    fi
}

function vet_setup {
    local full="$1"
    local not_set="!!! NOT SET !!!"
    local redmine_endpoint_display="${redmine_endpoint:-$not_set}"
    local redmine_user_id_display="${redmine_user_id:-$not_set}"
    local github_endpoint_display="${github_endpoint:-$not_set}"
    local github_user_display="${github_user:-$not_set}"
    local upstream_remote_display="${upstream_remote:-$not_set}"
    local fork_remote_display="${fork_remote:-$not_set}"
    local redmine_key_display=""
    local github_token_display=""
    if [ "$full" ] ; then 
        verbose Checking mandatory variables
        vet_github_user "$github_user"
        vet_remotes
        [ "$github_token" ] && vet_github_token "$github_token" "$github_token"
        [ "$redmine_key" ] && vet_redmine_key "$redmine_key" "$redmine_key"
    fi
    [ "$github_token" ] && github_token_display="(OK; value not shown)" || github_token_display="$not_set"
    [ "$redmine_key" ] && redmine_key_display="(OK; value not shown)" || redmine_key_display="$not_set"
    test "$redmine_endpoint" || failed_mandatory_var_check redmine_endpoint "not set"
    test "$redmine_user_id"  || failed_mandatory_var_check redmine_user_id "not set"
    test "$redmine_key"      || failed_mandatory_var_check redmine_key "not set"
    test "$github_endpoint"  || failed_mandatory_var_check github_endpoint "not set"
    test "$github_user"      || failed_mandatory_var_check github_user "not set"
    test "$github_token"     || failed_mandatory_var_check github_token "not set"
    test "$upstream_remote"  || failed_mandatory_var_check upstream_remote "not set"
    test "$fork_remote"      || failed_mandatory_var_check fork_remote "not set"
    if [ "$full" ] || [ "$INTERACTIVE_SETUP_ROUTINE" ] ; then
        read -r -d '' setup_summary <<EOM || true > /dev/null 2>&1
redmine_endpoint $redmine_endpoint
redmine_user_id  $redmine_user_id_display
redmine_key      $redmine_key_display
github_endpoint  $github_endpoint
github_user      $github_user_display
github_token     $github_token_display
upstream_remote  $upstream_remote_display
fork_remote      $fork_remote_display
EOM
        log bare
        log bare "================================"
        log bare "${this_script} setup report"
        log bare "--------------------------------"
        log bare "variable name    value"
        log bare "--------------------------------"
        log bare "$setup_summary"
        log bare "================================"
    else
        verbose "redmine_endpoint $redmine_endpoint_display"
        verbose "redmine_user_id  $redmine_user_id_display"
        verbose "redmine_key      $redmine_key_display"
        verbose "github_endpoint  $github_endpoint_display"
        verbose "github_user      $github_user_display"
        verbose "github_token     $github_token_display"
        verbose "upstream_remote  $upstream_remote_display"
        verbose "fork_remote      $fork_remote_display"
    fi
    if [ "$not_silent" ] ; then
        echo "Setup state is $setup_state"
    fi
}

function warning {
    log warning "$@"
}


#
# are we in a local git clone?
#

if git status >/dev/null 2>&1 ; then
    debug "In a local git clone. Good."
else
    error "This script must be run from inside a local git clone"
    abort_due_to_setup_problem
fi


#
# process command-line arguments
#

munged_options=$(getopt -o c:dhsv --long "cherry-pick-only,component:,debug,existing-pr:,force,help,milestones,setup,setup-report,troubleshooting,update-version,usage,verbose,version" -n "$this_script" -- "$@")
eval set -- "$munged_options"

ADVICE=""
CHECK_MILESTONES=""
CHERRY_PICK_ONLY=""
DEBUG=""
EXISTING_PR=""
EXPLICIT_COMPONENT=""
FORCE=""
HELP=""
INTERACTIVE_SETUP_ROUTINE=""
ISSUE=""
SETUP_REPORT=""
TROUBLESHOOTING_ADVICE=""
USAGE_ADVICE=""
VERBOSE=""
while true ; do
    case "$1" in
        --cherry-pick-only) CHERRY_PICK_ONLY="$1" ; shift ;;
        --component|-c) shift ; EXPLICIT_COMPONENT="$1" ; shift ;;
        --debug|-d) DEBUG="$1" ; shift ;;
        --existing-pr) shift ; EXISTING_PR="$1" ; shift ;;
        --force) FORCE="$1" ; shift ;;
        --help|-h) ADVICE="1" ; HELP="$1" ; shift ;;
        --milestones) CHECK_MILESTONES="$1" ; shift ;;
        --setup|-s) INTERACTIVE_SETUP_ROUTINE="$1" ; shift ;;
        --setup-report) SETUP_REPORT="$1" ; shift ;;
        --troubleshooting) ADVICE="$1" ; TROUBLESHOOTING_ADVICE="$1" ; shift ;;
        --update-version) update_version_number_and_exit ;;
        --usage) ADVICE="$1" ; USAGE_ADVICE="$1" ; shift ;;
        --verbose|-v) VERBOSE="$1" ; shift ;;
        --version) display_version_message_and_exit ;;
        --) shift ; ISSUE="$1" ; break ;;
        *) echo "Internal error" ; false ;;
    esac
done

if [ "$ADVICE" ] ; then
    [ "$HELP" ] && usage
    [ "$USAGE_ADVICE" ] && usage_advice
    [ "$TROUBLESHOOTING_ADVICE" ] && troubleshooting_advice
    exit 0
fi

if [ "$SETUP_REPORT" ] || [ "$INTERACTIVE_SETUP_ROUTINE" ] || [ "$CHECK_MILESTONES" ] ; then
    ISSUE="0"
fi

if [[ $ISSUE =~ ^[0-9]+$ ]] ; then
    issue=$ISSUE
else
    error "Invalid or missing argument"
    usage
    false
fi

if [ "$DEBUG" ]; then
    set -x
    VERBOSE="--verbose"
fi

if [ "$VERBOSE" ]; then
    info "Verbose mode ON"
    VERBOSE="--verbose"
fi


#
# initialize mandatory variables and check values for sanity
#

setup_ok="1"
setup_state="OK"
init_endpoints
github_user="$(from_file github_user)"
github_token="$(from_file github_token)"
redmine_key="$(from_file redmine_key)"
redmine_user_id="$(from_file redmine_user_id)"
if [ "$github_user" ] ; then
    verbose "GitHub user: $github_user"
else
    warning "github_user not set"
    SETUP_REPORT=""
    INTERACTIVE_SETUP_ROUTINE="--setup"
fi
[ "$INTERACTIVE_SETUP_ROUTINE" ] && interactive_setup_routine
init_upstream_remote
init_fork_remote
if [ "$SETUP_REPORT" ] ; then
    vet_setup --full
    VERBOSE="yes"
fi 
[ "$setup_ok" ] || abort_due_to_setup_problem
if [ "$INTERACTIVE_SETUP_ROUTINE" ] || [ "$SETUP_REPORT" ] ; then
    info "Setup is OK"
    echo
    exit 0
fi

#
# query remote GitHub API for active milestones
#

verbose "Querying GitHub API for active milestones"
remote_api_output="$(curl --silent -X GET "https://api.github.com/repos/ceph/ceph/milestones?access_token=$github_token")"
active_milestones="$(echo "$remote_api_output" | jq -r '.[] | .title')"
if [ "$active_milestones" = "null" ] ; then
    error "Could not determine the active milestones"
    bail_out_github_api "$remote_api_output"
fi

if [ "$CHECK_MILESTONES" ] ; then
    check_milestones "$active_milestones"
    exit 0
fi

#
# query remote Redmine API for information about the Backport tracker issue
#

redmine_url="${redmine_endpoint}/issues/${issue}"
debug "Considering Redmine issue: $redmine_url - is it in the Backport tracker?"

remote_api_output="$(curl --silent "${redmine_url}.json")"
tracker="$(echo "$remote_api_output" | jq -r '.issue.tracker.name')"
if [ "$tracker" = "Backport" ]; then
    debug "Yes, $redmine_url is a Backport issue"
else
    error "Issue $redmine_url is not a Backport"
    info "(This script only works with Backport tracker issues.)"
    false
fi

debug "Looking up release/milestone of $redmine_url"
milestone="$(echo "$remote_api_output" | jq -r '.issue.custom_fields[0].value')"
if [ "$milestone" ] ; then
    debug "Release/milestone: $milestone"
else
    error "could not obtain release/milestone from ${redmine_url}"
    false
fi

debug "Looking up status of $redmine_url"
tracker_status_id="$(echo "$remote_api_output" | jq -r '.issue.status.id')"
tracker_status_name="$(echo "$remote_api_output" | jq -r '.issue.status.name')"
if [ "$tracker_status_name" ] ; then
    debug "Tracker status: $tracker_status_name"
    if [ "$FORCE" ] ; then
        test "$(check_tracker_status "$tracker_status_name")" || true
    else
        test "$(check_tracker_status "$tracker_status_name")"
    fi
else
    error "could not obtain status from ${redmine_url}"
    false
fi

tracker_title="$(echo "$remote_api_output" | jq -r '.issue.subject')"
debug "Title of $redmine_url is ->$tracker_title<-"

tracker_description="$(echo "$remote_api_output" | jq -r '.issue.description')"
debug "Description of $redmine_url is ->$tracker_description<-"

tracker_assignee_id="$(echo "$remote_api_output" | jq -r '.issue.assigned_to.id')"
tracker_assignee_name="$(echo "$remote_api_output" | jq -r '.issue.assigned_to.name')"
if [ "$tracker_assignee_id" = "null" ] || [ "$tracker_assignee_id" = "$redmine_user_id" ] ; then
    true
else
    error_msg_1="$redmine_url is assigned to someone else: $tracker_assignee_name (ID $tracker_assignee_id)"
    error_msg_2="(my ID is $redmine_user_id)"
    if [ "$FORCE" ] ; then
        warning "$error_msg_1"
        info "$error_msg_2"
        info "--force was given: continuing execution"
    else
        error "$error_msg_1"
        info "$error_msg_2"
        info "Cowardly refusing to continue"
        false
    fi
fi

if [ -z "$(is_active_milestone "$milestone")" ] ; then
    error "$redmine_url is a backport to $milestone which is not an active milestone"
    info "Cowardly refusing to work on a backport to an inactive release"
    false
fi

milestone_number=$(try_known_milestones "$milestone")
if [ "$milestone_number" -gt "0" ] >/dev/null 2>&1 ; then
    target_branch="$milestone"
else
    milestone_number=$(milestone_number_from_remote_api "$milestone")
fi
info "milestone/release is $milestone"
debug "milestone number is $milestone_number"


if [ "$EXISTING_PR" ] ; then
    info "backport PR#${EXISTING_PR} already exists; updating tracker only"
    backport_pr_number="$EXISTING_PR"
else
    #
    # cherry-pick phase
    #
    
    local_branch=wip-${issue}-${target_branch}
    skip_cherry_pick_phase="$CHERRY_PICK_ONLY"
    if git show-ref --verify --quiet "refs/heads/$local_branch" ; then
        if [ "$CHERRY_PICK_ONLY" ] ; then
            if [ "$FORCE" ] ; then
                warning "local branch $local_branch already exists"
                info "--force was given: will clobber $local_branch and attempt automated cherry-pick"
            else
                error "local branch $local_branch already exists"
                info "Cowardly refusing to clobber $local_branch as it might contain valuable data"
                info "(hint) run with --force to clobber it and attempt the cherry-pick"
                false
            fi
        else
            info "local branch $local_branch already exists: skipping cherry-pick phase"
            skip_cherry_pick_phase="yes"
        fi
    else
        info "$local_branch does not exist: will create it and attempt automated cherry-pick"
    fi
    [ "$skip_cherry_pick_phase" ] || cherry_pick_phase
    [ "$CHERRY_PICK_ONLY" ] && exit 0
    
    
    #
    # PR phase
    #
    
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$current_branch" = "$local_branch" ] || git checkout "$local_branch"
    
    debug "Pushing local branch $local_branch to remote $fork_remote"
    git push -u "$fork_remote" "$local_branch"
    
    original_issue=""
    original_pr=""
    original_pr_url=""
    
    debug "Generating backport PR description"
    populate_original_issue
    populate_original_pr
    desc="backport tracker: ${redmine_url}"
    if [ "$original_pr" ] || [ "$original_issue" ] ; then
        desc="${desc}\n\n---\n"
        [ "$original_pr"    ] && desc="${desc}\nbackport of ${github_endpoint}/pull/${original_pr}"
        [ "$original_issue" ] && desc="${desc}\nparent tracker: ${redmine_endpoint}/issues/${original_issue}"
    fi
    desc="${desc}\n\nthis backport was staged using ceph-backport.sh version ${SCRIPT_VERSION}\nfind the latest version at ${github_endpoint}/blob/master/src/script/ceph-backport.sh"
    
    debug "Generating backport PR title"
    if [ "$original_pr" ] ; then
        title="${milestone}: $(curl --silent https://api.github.com/repos/ceph/ceph/pulls/${original_pr} | jq -r '.title')"
    else
        if [[ $tracker_title =~ ^${milestone}: ]] ; then
            title="${tracker_title}"
        else
            title="${milestone}: ${tracker_title}"
        fi
    fi
    if [[ $title =~ \" ]] ; then
        #title="$(echo "$title" | sed -e 's/"/\\"/g')"
        title="${title//\"/\\\"}"
    fi
    
    debug "Opening backport PR"
    remote_api_output=$(curl --silent --data-binary "{\"title\":\"${title}\",\"head\":\"${github_user}:${local_branch}\",\"base\":\"${target_branch}\",\"body\":\"${desc}\"}" "https://api.github.com/repos/ceph/ceph/pulls?access_token=${github_token}")
    backport_pr_number=$(echo "$remote_api_output" | jq -r .number)
    if [ -z "$backport_pr_number" ] || [ "$backport_pr_number" = "null" ] ; then
        bail_out_github_api "$remote_api_output"
    fi
    backport_pr_url="${github_endpoint}/pull/$backport_pr_number"
    info "Opened backport PR ${backport_pr_url}"
    
    if [ "$EXPLICIT_COMPONENT" ] ; then
        debug "Component given on command line: using it"
        component="$EXPLICIT_COMPONENT"
    else
        debug "Attempting to guess component"
        component=$(guess_component "$title")
    fi
    if [ "$component" ] ; then
        debug "Attempting to set ${component} label and ${milestone} milestone in ${backport_pr_url}"
        data_binary='{"milestone":'$milestone_number',"labels":["'$component'"]}'
    else
        debug "Attempting to set ${milestone} milestone in ${backport_pr_url}"
        data_binary='{"milestone":'$milestone_number'}'
    fi
    blindly_set_pr_metadata "$backport_pr_number" "$data_binary"
    
    pgrep firefox >/dev/null && firefox "${backport_pr_url}"
fi

debug "Considering Backport tracker issue ${redmine_url}"
status_should_be=2 # In Progress
desc_should_be="https://github.com/ceph/ceph/pull/${backport_pr_number}"
assignee_should_be="${redmine_user_id}"
remote_api_status_code="$(curl --write-out '%{http_code}' --output /dev/null --silent -X PUT --header "Content-type: application/json" --data-binary "{\"issue\":{\"description\":\"${desc_should_be}\",\"status_id\":${status_should_be},\"assigned_to_id\":${assignee_should_be},\"notes\":\"ceph-backport.sh version ${SCRIPT_VERSION}: attempting to link this Backport tracker issue with GitHub PR ${desc_should_be}\"}}" "${redmine_url}.json?key=$redmine_key")"
if [ "${remote_api_status_code:0:1}" = "2" ] ; then
    true
elif [ "${remote_api_status_code:0:1}" = "4" ] ; then
    error "Remote API ${redmine_endpoint} returned status ${remote_api_status_code}"
    info "This indicates an authentication/authorization problem: is your API access key valid?"
else
    error "Remote API ${redmine_endpoint} returned unexpected response code ${remote_api_status_code}"
fi
# check if anything actually changed on the Redmine issue
remote_api_output=$(curl --silent "${redmine_url}.json?include=journals")
status_is="$(echo "$remote_api_output" | jq -r '.issue.status.id')"
desc_is="$(echo "$remote_api_output" | jq -r '.issue.description')"
assignee_is="$(echo "$remote_api_output" | jq -r '.issue.assigned_to.id')"
tracker_was_updated=""
tracker_is_in_desired_state="yes"
[ "$(tracker_component_was_updated "status" "$tracker_status_id" "$status_is")" ] && tracker_was_updated="yes"
[ "$(tracker_component_was_updated "desc" "$tracker_description" "$desc_is")" ] && tracker_was_updated="yes"
[ "$(tracker_component_was_updated "assignee" "$tracker_assignee_id" "$assignee_is")" ] && tracker_was_updated="yes"
[ "$(tracker_component_is_in_desired_state "status" "$status_is" "$status_should_be")" ] || tracker_is_in_desired_state=""
[ "$(tracker_component_is_in_desired_state "desc" "$desc_is" "$desc_should_be")" ] || tracker_is_in_desired_state=""
[ "$(tracker_component_is_in_desired_state "assignee" "$assignee_is" "$assignee_should_be")" ] || tracker_is_in_desired_state=""
[ "$tracker_was_updated" ] && info "Tracker ${redmine_url} was updated"
if [ "$tracker_is_in_desired_state" ] ; then
    info "Backport tracker issue ${redmine_url} is in the desired state"
    pgrep firefox >/dev/null && firefox "${redmine_url}"
else
    # user probably lacks sufficient Redmine privileges, but this is not
    # a problem
    info "Comment added to ${redmine_url}"
fi
