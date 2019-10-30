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
# Setup, usage and troubleshooting:
#
#     ceph-backport.sh --help
#     ceph-backport.sh --setup-advice
#     ceph-backport.sh --usage-advice
#     ceph-backport.sh --troubleshooting-advice
#
#

SCRIPT_VERSION="15.0.0.6270"
full_path="$0"
this_script=$(basename "$full_path")
how_to_get_setup_advice="For setup advice, run: \"${this_script} --setup-advice | less\""

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

function bail_out_github_api {
    local api_said="$1"
    info "GitHub API said:"
    log bare "$api_said"
    info "For setup report, run:  ${this_script} --setup"
    info "For setup advice, run:  ${this_script} --setup-advice"
    info "(hint) Check the value of github_token"
    info "(hint) Run the script with --debug"
    false
}

function blindly_set_pr_metadata {
    local pr_number="$1"
    local json_blob="$2"
    curl --silent --data-binary "$json_blob" 'https://api.github.com/repos/ceph/ceph/issues/'$pr_number'?access_token='$github_token >/dev/null 2>&1 || true
}

function check_milestones {
    local milestones_to_check="$(echo "$1" | tr '\n' ' ' | xargs)"
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
            error "Backport $redmine_url is already in progress"
            false
        else
            error "Backport $redmine_url is closed (status: ${ts})"
            false
        fi
    fi
    echo "$tslc_is_ok"
}

function cherry_pick_phase {
    local base_branch=
    local merged=
    local number_of_commits=
    local offset=0
    local singular_or_plural_commit=
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
    remote_api_output=$(curl --silent https://api.github.com/repos/ceph/ceph/pulls/${original_pr}?access_token=${github_token})
    base_branch=$(echo ${remote_api_output} | jq -r .base.label)
    if [ "$base_branch" = "ceph:master" ] ; then
        true
    else
        error "${original_pr_url} is targeting ${base_branch}: cowardly refusing to perform automated cherry-pick"
        info "Out of an abundance of caution, the script only automates cherry-picking of commits from PRs targeting \"ceph:master\"."
        info "You can still use the script to stage the backport, though. Just prepare the local branch \"${local_branch}\" manually and re-run the script."
        false
    fi
    merged=$(echo ${remote_api_output} | jq -r .merged)
    if [ "$merged" = "true" ] ; then
        true
    else
        error "${original_pr_url} is not merged yet: cowardly refusing to perform automated cherry-pick"
        false
    fi
    number_of_commits=$(echo ${remote_api_output} | jq .commits)
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
    git fetch $upstream_remote

    debug "Initializing local branch $local_branch to $milestone"
    if git show-ref --verify --quiet refs/heads/$local_branch ; then
        error "Cannot initialize $local_branch - local branch already exists"
        false
    else
        git checkout $upstream_remote/$milestone -b $local_branch
    fi

    debug "Fetching latest commits from ${original_pr_url}"
    git fetch $upstream_remote pull/$original_pr/head:pr-$original_pr

    info "Attempting to cherry pick $number_of_commits commits from ${original_pr_url} into local branch $local_branch"
    let offset=${number_of_commits}-1 || true # don't fail on set -e when result is 0
    for ((i=$offset; i>=0; i--)) ; do
        debug "Cherry-picking commit $(git log --oneline --max-count=1 --no-decorate pr-$original_pr~$i)"
        if git cherry-pick -x "pr-$original_pr~$i" ; then
            true
        else
            [ "$VERBOSE" ] && git status
            error "Cherry pick failed"
            info "Next, manually fix conflicts and complete the current cherry-pick"
            if [ "$i" -gt "0" ] >/dev/null 2>&1 ; then
                info "Then, cherry-pick the remaining commits from ${original_pr_url}, i.e.:"
                for ((j=$i-1; j>=0; j--)) ; do
                    info "-> missing commit: $(git log --oneline --max-count=1 --no-decorate pr-$original_pr~$j)"
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

function deduce_remote {
    local remote_type="$1"
    local remote=""
    local url_component=""
    if [ "$remote_type" = "upstream" ] ; then
        url_component="ceph"
    elif [ "$remote_type" = "fork" ] ; then
        url_component="$github_user"
    else
        error "Internal error in deduce_remote"
        false
    fi
    remote=$(git remote -v | egrep --ignore-case '(://|@)github.com(/|:)'$url_component'/ceph(\s|\.|\/)' | head -n1 | cut -f 1)
    if [ "$remote" ] ; then
        true
    else
        error "Cannot auto-determine ${remote_type}_remote"
        info "There is something wrong with your remotes - to start with, check 'git remote -v'"
        false
    fi
    echo "$remote"
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
    log mtt=$1
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
}

function flag_pr {
    local pr_num="$1"
    local pr_url="$2"
    local flag_reason="$3"
    warning "flagging PR#${pr_num} because $flag_reason"
    flagged_pr_hash["${pr_url}"]="$flag_reason"
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

function init_remotes {
    # if github_user is not set, we cannot initialize fork_remote
    vet_github_user
    verbose "Initializing GitHub repos (\"remotes\")"
    upstream_remote="${upstream_remote:-$(deduce_remote upstream)}"
    fork_remote="${fork_remote:-$(deduce_remote fork)}"
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
    local msg="$@"
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
    if [ "$verbose_only" -a -z "$VERBOSE" ] ; then
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

function milestone_number_from_remote_api {
    local mtt=$1  # milestone to try
    local mn=""   # milestone number
    warning "Milestone ->$mtt<- unknown to script - falling back to GitHub API"
    remote_api_output=$(curl --silent -X GET 'https://api.github.com/repos/ceph/ceph/milestones?access_token='$github_token)
    mn=$(echo $remote_api_output | jq --arg milestone $mtt '.[] | select(.title==$milestone) | .number')
    if [ "$mn" -gt "0" ] >/dev/null 2>&1 ; then
        echo "$mn"
    else
        error "Could not determine milestone number of ->$milestone<-"
        verbose_en "GitHub API said:\n${remote_api_output}\n"
        info "Valid values are $(curl --silent -X GET 'https://api.github.com/repos/ceph/ceph/milestones?access_token='$github_token | jq '.[].title')"
        info "(This probably means the Release field of ${redmine_url} is populated with"
        info "an unexpected value - i.e. it does not match any of the GitHub milestones.)"
        false
    fi
}

function populate_original_issue {
    if [ -z "$original_issue" ] ; then
        original_issue=$(curl --silent ${redmine_url}.json?include=relations |
            jq '.issue.relations[] | select(.relation_type | contains("copied_to")) | .issue_id')
    fi
}

function populate_original_pr {
    if [ "$original_issue" ] ; then
        if [ -z "$original_pr" ] ; then
            original_pr=$(curl --silent ${redmine_endpoint}/issues/${original_issue}.json |
                          jq -r '.issue.custom_fields[] | select(.id | contains(21)) | .value')
            original_pr_url="${github_endpoint}/pull/${original_pr}"
        fi
    fi
}

function setup_advice {
    cat <<EOM
Setup advice
------------

${this_script} expects to be run inside a local clone of the Ceph git repo.
Some initial setup is required for the script to become fully functional.

First, obtain the correct values for the following variables:

redmine_key     # "My account" -> "API access key" -> "Show"
redmine_user_id # "Logged in as foobar", click on foobar link, Redmine User ID
                # is in the URL, i.e. https://tracker.ceph.com/users/[redmine_user_id]
github_token    # https://github.com/settings/tokens -> Generate new token ->
                # ensure it has "Full control of private repositories" scope
                # see also:
                # https://help.github.com/en/articles/creating-a-personal-access-token-for-the-command-line
github_user     # Your github username

The above variables must be set explicitly, as the script has no way of
determining reasonable defaults. If you prefer, you can ensure the variables
are set in the environment before running the script. Alternatively, you can
create a file, \$HOME/bin/backport_common.sh (this exact path), with the
variable assignments in it. The script will detect that the file exists and
"source" it.

In any case, care should be taken to keep the values of redmine_key and
github_token secret.

The script expects to run in a local clone of a Ceph repo with
at least two remotes defined - pointing to:

    https://github.com/ceph/ceph.git
    https://github.com/\$github_user/ceph.git

In other words, the upstream GitHub repo and the user's fork thereof. It makes
no difference what these remotes are called - the script will determine the
right remote names automatically.

To find out whether you have any obvious problems with your setup before
actually using the script to stage a backport, run:

    ${this_script} --setup

EOM
}

function setup_report {
    local not_set="!!! NOT SET !!!"
    local set_but_not_valid="!!! SET, BUT NOT VALID !!!"
    local redmine_endpoint_display="${redmine_endpoint:-$not_set}"
    local redmine_user_id_display="${redmine_user_id:-$not_set}"
    local github_endpoint_display="${github_endpoint:-$not_set}"
    local github_user_display="${github_user:-$not_set}"
    local upstream_remote_display="${upstream_remote:-$not_set}"
    local fork_remote_display="${fork_remote:-$not_set}"
    local redmine_key_display=""
    local github_token_display=""
    verbose Checking mandatory variables
    if [ "$github_token" ] ; then
        if [ "$(vet_github_token)" ] ; then
            github_token_display="(OK, not shown)"
        else
            github_token_display="$set_but_not_valid"
            failed_mandatory_var_check github_token "set, but not valid"
        fi
    else
        github_token_display="$not_set"
        failed_mandatory_var_check github_token "not set"
    fi
    [ "$redmine_key" ] && redmine_key_display="(OK, not shown)" || redmine_key_display="$not_set"
    test "$redmine_key"      || failed_mandatory_var_check redmine_key "not set"
    test "$redmine_user_id"  || failed_mandatory_var_check redmine_user_id "not set"
    test "$github_user"      || failed_mandatory_var_check github_user "not set"
    test "$upstream_remote"  || failed_mandatory_var_check upstream_remote "not set"
    test "$fork_remote"      || failed_mandatory_var_check fork_remote "not set"
    test "$redmine_endpoint" || failed_mandatory_var_check redmine_endpoint "not set"
    test "$github_endpoint"  || failed_mandatory_var_check github_endpoint "not set"
    if [ "$SETUP_ONLY" ] ; then
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
        log bare "================================"
        log bare "Setup report"
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
        octopus) echo "Octopus milestone number is unknown! Update the script now." ; exit -1 ;;
    esac
    echo "$mn"
}

function update_version_number_and_exit {
    set -x
    local raw_version=$(git describe --long --match 'v*' | sed 's/^v//')
    # raw_version will look like this: 15.0.0-5774-g4c2f2eda969
    local munge_first_hyphen=${raw_version/-/.}
    # munge_first_hyphen will look like this: 15.0.0.5774-g4c2f2eda969
    local script_version_number=${munge_first_hyphen%-*}
    # script_version_number will look like this: 15.0.0.5774
    sed -i -e 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="'"$script_version_number"'"/' $full_path
    exit 0
}

function usage {
    cat <<EOM >&2
Documentation:

   ${this_script} --setup-advice | less
   ${this_script} --usage-advice | less
   ${this_script} --troubleshooting-advice | less

Usage:
   ${this_script} --setup
   ${this_script} BACKPORT_TRACKER_ISSUE_NUMBER

Options (not needed in normal operation):
    --cherry-pick-only (stop after cherry-pick phase)
    -c/--component COMPONENT
                       (explicitly set the component label; if omitted, the
                        script will try to guess the component)
    --debug            (turns on "set -x")
    --milestones       (vet all backport PRs for correct milestone setting)
    -s/--setup         (check the setup and report any problems found)
    --update-version   (this option exists as a convenience for the script
                        maintainer only: not intended for day-to-day usage)
    -v/--verbose       (produce more output than normal)
    --version          (display version number and exit)

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

Once you have completed setup (see --setup-advice), you can run the script
with the ID of a Backport tracker issue. For example, to stage the backport
https://tracker.ceph.com/issues/41502, run:

    ${this_script} 41502

If the commits in the corresponding master PR cherry-pick cleanly, the script
will automatically perform all steps required to stage the backport:

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
    # github_token is set, but we don't know, yet, if the remote API will honor
    # it. Fortunately, with GitHub it's simple:
    #
    # $ curl --silent https://api.github.com/repos/ceph/ceph/pulls/19999?access_token=invalid
    # {
    #   "message": "Bad credentials",
    #   "documentation_url": "https://developer.github.com/v3"
    # }
    #
    local number=
    local test_pr_id='19999'
    remote_api_output=$(curl --silent https://api.github.com/repos/ceph/ceph/pulls/${test_pr_id}?access_token=${github_token})
    number=$(echo ${remote_api_output} | jq .number)
    # in invalid case, $number will be equal to "null"
    # in valid case, it will be "19999"
    if [ "$number" -eq "$test_pr_id" ] 2>/dev/null ; then
        echo "valid"
    else
        echo ""
    fi
}

function vet_github_user {
    if [ "$github_user" ] ; then
        true
    else
        failed_mandatory_var_check github_user "not set"
        info "$how_to_get_setup_advice"
        false
    fi
}

function vet_pr_milestone {
    local pr_number="$1"
    local pr_title="$2"
    local pr_url="$3"
    local milestone_stanza="$4"
    local milestone_title_should_be="$5"
    local milestone_number_should_be=$(try_known_milestones "$milestone_title_should_be")
    local milestone_number_is=
    local milestone_title_is=
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
    remote_api_output=$(curl --silent --head https://api.github.com/repos/ceph/ceph/pulls?base=${milestone_title}\&access_token=${github_token} | grep -E '^Link' || true)
    if [ "$remote_api_output" ] ; then
         # Link: <https://api.github.com/repositories/2310495/pulls?base=luminous&access_token=f9b0beb6922e418663396f3ff2ab69467a3268f9&page=2>; rel="next", <https://api.github.com/repositories/2310495/pulls?base=luminous&access_token=f9b0beb6922e418663396f3ff2ab69467a3268f9&page=2>; rel="last"
         pages_of_output=$(echo "$remote_api_output" | sed 's/^.*&page\=\([0-9]\+\)>; rel=\"last\".*$/\1/g')
    else
         pages_of_output="1"
    fi
    verbose "GitHub has $pages_of_output pages of pull request data for \"base:${milestone_title}\""
    for ((page=1; page<=${pages_of_output}; page++)) ; do
        verbose "Fetching PRs (page $page of ${pages_of_output})"
        remote_api_output=$(curl --silent -X GET https://api.github.com/repos/ceph/ceph/pulls?base=${milestone_title}\&access_token=${github_token}\&page=${page})
        prs_in_page=$(echo "$remote_api_output" | jq -r '. | length')
        verbose "Page $page of remote API output contains information on $prs_in_page PRs"
        for ((i=0; i<${prs_in_page}; i++)) ; do
            pr_number=$(echo "$remote_api_output" | jq -r '.['$i'].number')
            pr_title=$(echo "$remote_api_output" | jq -r '.['$i'].title')
            pr_url="${github_endpoint}/pull/${pr_number}"
            milestone_stanza=$(echo "$remote_api_output" | jq -r '.['$i'].milestone')
            vet_pr_milestone "$pr_number" "$pr_title" "$pr_url" "$milestone_stanza" "$milestone_title"
        done
        clear_line
    done
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
    info "$how_to_get_setup_advice"
    false
fi


#
# process command-line arguments
#

munged_options=$(getopt -o c:dhsv --long "cherry-pick-only,component:,debug,help,milestones,setup,setup-advice,troubleshooting-advice,update-version,usage-advice,verbose,version" -n "$this_script" -- "$@")
eval set -- "$munged_options"

ADVICE=""
CHECK_MILESTONES=""
CHERRY_PICK_ONLY=""
DEBUG=""
EXPLICIT_COMPONENT=""
HELP=""
ISSUE=""
SETUP_ADVICE=""
SETUP_ONLY=""
TROUBLESHOOTING_ADVICE=""
USAGE_ADVICE=""
VERBOSE=""
while true ; do
    case "$1" in
        --cherry-pick-only) CHERRY_PICK_ONLY="$1" ; shift ;;
        --component|-c) shift ; EXPLICIT_COMPONENT="$1" ; shift ;;
        --debug|-d) DEBUG="$1" ; shift ;;
        --help|-h) ADVICE="1" ; HELP="$1" ; shift ;;
        --milestones) CHECK_MILESTONES="$1" ; shift ;;
        --setup|-s) SETUP_ONLY="$1" ; shift ;;
        --setup-advice) ADVICE="1" ; SETUP_ADVICE="$1" ; shift ;;
        --trouble*) ADVICE="$1" ; TROUBLESHOOTING_ADVICE="$1" ; shift ;;
        --update*) update_version_number_and_exit ;;
        --usage-advice) ADVICE="$1" ; USAGE_ADVICE="$1" ; shift ;;
        --verbose|-v) VERBOSE="$1" ; shift ;;
        --version) display_version_message_and_exit ;;
        --) shift ; ISSUE="$1" ; break ;;
        *) echo "Internal error" ; false ;;
    esac
done

if [ "$ADVICE" ] ; then
    [ "$HELP" ] && usage
    [ "$SETUP_ADVICE" ] && setup_advice
    [ "$USAGE_ADVICE" ] && usage_advice
    [ "$TROUBLESHOOTING_ADVICE" ] && troubleshooting_advice
    exit 0
fi

[ "$SETUP_ONLY" -o "$CHECK_MILESTONES" ] && ISSUE="0"
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

BACKPORT_COMMON=$HOME/bin/backport_common.sh
[ -f "$BACKPORT_COMMON" ] && source "$BACKPORT_COMMON"
setup_ok="1"
init_endpoints
init_remotes
setup_report
if [ "$setup_ok" ] ; then
    if [ "$SETUP_ONLY" ] ; then
        log bare "Overall setup is OK"
        exit 0
    elif [ "$VERBOSE" ] ; then
        debug "Overall setup is OK"
    fi
else
    if [ "$SETUP_ONLY" ] ; then
        log bare "Setup is NOT OK"
        log bare "$how_to_get_setup_advice"
        false
    else
        error "Problem detected in your setup"
        info "Run the script with --setup for a full report"
        info "$how_to_get_setup_advice"
        false
    fi
fi

#
# query remote GitHub API for active milestones
#

verbose "Querying GitHub API for active milestones"
remote_api_output="$(curl --silent -X GET 'https://api.github.com/repos/ceph/ceph/milestones?access_token='$github_token)"
active_milestones="$(echo $remote_api_output | jq -r '.[] | .title')"
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

remote_api_output=$(curl --silent "${redmine_url}.json")
tracker=$(echo $remote_api_output | jq -r '.issue.tracker.name')
if [ "$tracker" = "Backport" ]; then
    debug "Yes, $redmine_url is a Backport issue"
else
    error "Issue $redmine_url is not a Backport"
    info "(This script only works with Backport tracker issues.)"
    false
fi

debug "Looking up release/milestone of $redmine_url"
milestone=$(echo $remote_api_output | jq -r '.issue.custom_fields[0].value')
if [ "$milestone" ] ; then
    debug "Release/milestone: $milestone"
else
    error "could not obtain release/milestone from ${redmine_url}"
    false
fi

debug "Looking up status of $redmine_url"
tracker_status=$(echo $remote_api_output | jq -r '.issue.status.name')
if [ "$tracker_status" ] ; then
    debug "Tracker status: $tracker_status"
    test "$(check_tracker_status "$tracker_status")"
else
    error "could not obtain status from ${redmine_url}"
    false
fi

tracker_title=$(echo $remote_api_output | jq -r '.issue.subject')
debug "Title of $redmine_url is ->$tracker_title<-"

tracker_assignee_id=$(echo $remote_api_output | jq -r '.issue.assigned_to.id')
tracker_assignee_name=$(echo $remote_api_output | jq -r '.issue.assigned_to.name')
debug "$redmine_url is assigned to $tracker_assignee_name (ID $tracker_assignee_id)"

if [ "$tracker_assignee_id" = "null" -o "$tracker_assignee_id" = "$redmine_user_id" ] ; then
    true
else
    error "$redmine_url is assigned to $tracker_assignee_name (ID $tracker_assignee_id)"
    info "Cowardly refusing to work on an issue that is assigned to someone else"
    false
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
info "Milestone/release is $milestone"
debug "Milestone number is $milestone_number"


#
# cherry-pick phase
#

local_branch=wip-${issue}-${target_branch}
if git show-ref --verify --quiet refs/heads/$local_branch ; then
    if [ "$CHERRY_PICK_ONLY" ] ; then
        error "local branch $local_branch already exists -- cannot -prepare"
        false
    fi
    info "local branch $local_branch already exists: skipping cherry-pick phase"
else
    info "$local_branch does not exist: will create it and attempt automated cherry-pick"
    cherry_pick_phase
    [ "$CHERRY_PICK_ONLY" ] && exit 0
fi


#
# PR phase
#

current_branch=$(git rev-parse --abbrev-ref HEAD)
[ "$current_branch" = "$local_branch" ] || git checkout $local_branch

debug "Pushing local branch $local_branch to remote $fork_remote"
git push -u $fork_remote $local_branch

original_issue=""
original_pr=""
original_pr_url=""

debug "Generating backport PR description"
populate_original_issue
populate_original_pr
desc="backport tracker: ${redmine_url}"
if [ "$original_pr" -o "$original_issue" ] ; then
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
    title=$(echo $title | sed -e 's/"/\\"/g')
fi

debug "Opening backport PR"
remote_api_output=$(curl --silent --data-binary '{"title":"'"$title"'","head":"'$github_user':'$local_branch'","base":"'$target_branch'","body":"'"${desc}"'"}' 'https://api.github.com/repos/ceph/ceph/pulls?access_token='$github_token)
backport_pr_number=$(echo "$remote_api_output" | jq -r .number)
if [ -z "$backport_pr_number" -o "$backport_pr_number" = "null" ] ; then
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

pgrep firefox >/dev/null && firefox ${backport_pr_url}

debug "Updating backport tracker issue ${redmine_url}"
redmine_status=2 # In Progress
remote_api_status_code=$(curl --write-out %{http_code} --output /dev/null --silent -X PUT --header 'Content-type: application/json' --data-binary '{"issue":{"description":"https://github.com/ceph/ceph/pull/'$backport_pr_number'","status_id":'$redmine_status',"assigned_to_id":'$redmine_user_id',"notes":"Updated automatically by ceph-backport.sh version '$SCRIPT_VERSION'"}}' ${redmine_url}'.json?key='$redmine_key)
if [ "${remote_api_status_code:0:1}" = "2" ] ; then
    info "${redmine_url} updated"
elif [ "${remote_api_status_code:0:1}" = "4" ] ; then
    error "Remote API ${redmine_endpoint} returned status ${remote_api_status_code}"
    info "This indicates an authentication/authorization problem: is your API access key valid?"
else
    error "Remote API ${redmine_endpoint} returned unexpected response code ${remote_api_status_code}"
fi
# check if anything actually changed on the Redmine issue
redmine_result_ok=""
remote_api_output=$(curl --silent "${redmine_url}.json")
tracker_description=$(echo $remote_api_output | jq -r '.issue.description')
if [[ "$tracker_description" =~ "$backport_pr_number" ]] ; then
    debug "Backport tracker description is set to ->${tracker_description}<-"
    true  # success
else
    info "Failed to automatically update ${redmine_url}."
    info "Please add a comment to ${redmine_url} to let others know that you"
    info "are working on the backport. In your comment, consider mentioning the"
    info "${backport_pr_url} (the URL of the backport PR that was just opened)."
fi
pgrep firefox >/dev/null && firefox ${redmine_url}
