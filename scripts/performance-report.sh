#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
project_root=${script_directory:h}
application_path="$project_root/dist/Feather.app"
repository_path=${1:-}
runs=${FEATHER_PERF_RUNS:-20}
temporary_files=()

function cleanup {
  if (( ${#temporary_files} )); then
    /bin/rm -f -- "${temporary_files[@]}"
  fi
}
trap cleanup EXIT

if [[ -n "$repository_path" ]]; then
  repository_path=${repository_path:A}
  if ! /usr/bin/git -C "$repository_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -u2 "Not a Git worktree: $repository_path"
    exit 2
  fi
fi

if [[ "$runs" != <1-> ]]; then
  print -u2 "FEATHER_PERF_RUNS must be a positive integer."
  exit 2
fi

print "Feather performance report"
print "captured_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
print "hardware=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)"
print "memory_bytes=$(/usr/sbin/sysctl -n hw.memsize)"
print "macos=$(/usr/bin/sw_vers -productVersion)"

if [[ -d "$application_path" ]]; then
  bundle_kib=$(/usr/bin/du -sk "$application_path" | /usr/bin/awk '{print $1}')
  architecture=$(/usr/bin/file "$application_path/Contents/MacOS/Feather" | /usr/bin/sed 's/^.*: //')
  print "bundle_kib=$bundle_kib"
  print "binary=$architecture"
else
  print "bundle=missing (run scripts/check-release.sh)"
fi

app_pids=(${(f)"$(/usr/bin/pgrep -x Feather 2>/dev/null || true)"})
if (( ${#app_pids} )); then
  pid_list=${(j:,:)app_pids}
  app_stats=$(/bin/ps -o rss=,pcpu= -p "$pid_list" | /usr/bin/awk \
    '{rss += $1; cpu += $2} END {printf "%d %.2f", rss, cpu}')
  print "feather_pids=$pid_list"
  print "feather_rss_kib=${app_stats%% *}"
  print "feather_cpu_percent=${app_stats##* }"
else
  print "feather=not_running"
fi

tmux_stats=$(/bin/ps -axo rss=,command= | /usr/bin/awk \
  '/Library\/Application Support\/(Feather|Barnacle)\/tmux\.conf/ {rss += $1; count += 1} END {printf "%d %d", count, rss}')
print "private_tmux_processes=${tmux_stats%% *}"
print "private_tmux_rss_kib=${tmux_stats##* }"

resource_timing_file=$(/usr/bin/mktemp -t feather-resource-times)
temporary_files+=("$resource_timing_file")
for _ in {1..$runs}; do
  started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
  /bin/ps -axo pid=,ppid=,rss=,pcpu=,command= >/dev/null
  finished=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
  /usr/bin/perl -e 'printf "%.3f\n", 1000 * ($ARGV[1] - $ARGV[0])' \
    "$started" "$finished" >> "$resource_timing_file"
done
sorted_resource_times=(${(f)"$(/usr/bin/sort -n "$resource_timing_file")"})
resource_median_index=$(( (${#sorted_resource_times} + 1) / 2 ))
resource_p95_index=$(( (${#sorted_resource_times} * 95 + 99) / 100 ))
resource_mean=$(/usr/bin/awk '{sum += $1} END {printf "%.3f", sum / NR}' "$resource_timing_file")
print "resource_sample_runs=$runs"
print "resource_sample_min_ms=${sorted_resource_times[1]}"
print "resource_sample_median_ms=${sorted_resource_times[$resource_median_index]}"
print "resource_sample_mean_ms=$resource_mean"
print "resource_sample_p95_ms=${sorted_resource_times[$resource_p95_index]}"
print "resource_sample_max_ms=${sorted_resource_times[-1]}"

if [[ -n "$repository_path" ]]; then
  tracked_files=$(/usr/bin/git -C "$repository_path" ls-files -z | /usr/bin/tr -cd '\0' | /usr/bin/wc -c | /usr/bin/tr -d ' ')
  timing_file=$(/usr/bin/mktemp -t feather-status-times)
  changes_timing_file=$(/usr/bin/mktemp -t feather-changes-times)
  quick_open_timing_file=$(/usr/bin/mktemp -t feather-quick-open-times)
  review_timing_file=$(/usr/bin/mktemp -t feather-review-times)
  search_timing_file=""
  ripgrep_executable=""
  for candidate in /opt/homebrew/bin/rg /usr/local/bin/rg; do
    if [[ -x "$candidate" ]]; then
      ripgrep_executable=$candidate
      break
    fi
  done
  if [[ -z "$ripgrep_executable" ]]; then
    ripgrep_executable=${commands[rg]:-}
  fi
  if [[ -n "$ripgrep_executable" ]]; then
    search_timing_file=$(/usr/bin/mktemp -t feather-search-times)
    temporary_files+=("$search_timing_file")
  fi
  temporary_files+=(
    "$timing_file"
    "$changes_timing_file"
    "$quick_open_timing_file"
    "$review_timing_file"
  )

  function refresh_changes {
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      status --porcelain=v2 --branch -z --untracked-files=all >/dev/null
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      diff --no-ext-diff --numstat -z -- >/dev/null &
    local worktree_pid=$!
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      diff --no-ext-diff --numstat -z --cached -- >/dev/null &
    local staged_pid=$!
    wait "$worktree_pid"
    wait "$staged_pid"
  }

  function quick_open_files {
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      ls-files -z --cached --others --exclude-standard >/dev/null
  }

  function repository_search {
    local search_status=0
    RIPGREP_CONFIG_PATH=/dev/null "$ripgrep_executable" \
      --json --fixed-strings --smart-case --line-number --column --hidden \
      --glob '!.git' --max-filesize 2M --max-count 20 --threads 2 -- \
      "${FEATHER_PERF_SEARCH_QUERY:-import}" "$repository_path" >/dev/null || search_status=$?
    (( search_status == 0 || search_status == 1 ))
  }

  review_base=$(GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$repository_path" \
    symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -z "$review_base" ]]; then
    for candidate in origin/main origin/master main master; do
      if GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$repository_path" \
        rev-parse --verify "$candidate^{commit}" >/dev/null 2>&1; then
        review_base=$candidate
        break
      fi
    done
  fi
  review_base=${review_base:-HEAD}
  review_available=0
  if GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$repository_path" \
    merge-base "$review_base" HEAD >/dev/null 2>&1; then
    review_available=1
  fi

  function refresh_branch_review {
    local resolved merge_base review_diff_pid review_status_pid
    resolved=$(GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$repository_path" \
      rev-parse --verify "$review_base^{commit}")
    merge_base=$(GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$repository_path" \
      merge-base "$resolved" HEAD)
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      diff --no-ext-diff --numstat -z "$merge_base" -- >/dev/null &
    review_diff_pid=$!
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      status --porcelain=v2 --branch -z --untracked-files=all >/dev/null &
    review_status_pid=$!
    wait "$review_diff_pid"
    wait "$review_status_pid"
  }

  GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
    status --porcelain=v2 --branch -z --untracked-files=all >/dev/null
  refresh_changes
  quick_open_files
  if [[ -n "$ripgrep_executable" ]]; then
    repository_search
  fi
  if (( review_available )); then
    refresh_branch_review
  fi

  for _ in {1..$runs}; do
    started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 /usr/bin/git -C "$repository_path" \
      status --porcelain=v2 --branch -z --untracked-files=all >/dev/null
    finished=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
    /usr/bin/perl -e 'printf "%.3f\n", 1000 * ($ARGV[1] - $ARGV[0])' \
      "$started" "$finished" >> "$timing_file"

    started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
    refresh_changes
    finished=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
    /usr/bin/perl -e 'printf "%.3f\n", 1000 * ($ARGV[1] - $ARGV[0])' \
      "$started" "$finished" >> "$changes_timing_file"

    started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
    quick_open_files
    finished=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
    /usr/bin/perl -e 'printf "%.3f\n", 1000 * ($ARGV[1] - $ARGV[0])' \
      "$started" "$finished" >> "$quick_open_timing_file"

    if [[ -n "$ripgrep_executable" ]]; then
      started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
      repository_search
      finished=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
      /usr/bin/perl -e 'printf "%.3f\n", 1000 * ($ARGV[1] - $ARGV[0])' \
        "$started" "$finished" >> "$search_timing_file"
    fi

    if (( review_available )); then
      started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
      refresh_branch_review
      finished=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.9f", time')
      /usr/bin/perl -e 'printf "%.3f\n", 1000 * ($ARGV[1] - $ARGV[0])' \
        "$started" "$finished" >> "$review_timing_file"
    fi
  done

  sorted_times=(${(f)"$(/usr/bin/sort -n "$timing_file")"})
  median_index=$(( (${#sorted_times} + 1) / 2 ))
  mean=$(/usr/bin/awk '{sum += $1} END {printf "%.3f", sum / NR}' "$timing_file")
  p95_index=$(( (${#sorted_times} * 95 + 99) / 100 ))
  sorted_changes_times=(${(f)"$(/usr/bin/sort -n "$changes_timing_file")"})
  changes_mean=$(/usr/bin/awk '{sum += $1} END {printf "%.3f", sum / NR}' "$changes_timing_file")
  sorted_quick_open_times=(${(f)"$(/usr/bin/sort -n "$quick_open_timing_file")"})
  quick_open_mean=$(/usr/bin/awk '{sum += $1} END {printf "%.3f", sum / NR}' "$quick_open_timing_file")
  if [[ -n "$ripgrep_executable" ]]; then
    sorted_search_times=(${(f)"$(/usr/bin/sort -n "$search_timing_file")"})
    search_mean=$(/usr/bin/awk '{sum += $1} END {printf "%.3f", sum / NR}' "$search_timing_file")
  fi

  print "repository=$repository_path"
  print "tracked_files=$tracked_files"
  print "git_status_runs=$runs"
  print "git_status_min_ms=${sorted_times[1]}"
  print "git_status_median_ms=${sorted_times[$median_index]}"
  print "git_status_mean_ms=$mean"
  print "git_status_p95_ms=${sorted_times[$p95_index]}"
  print "git_status_max_ms=${sorted_times[-1]}"
  print "changes_refresh_runs=$runs"
  print "changes_refresh_min_ms=${sorted_changes_times[1]}"
  print "changes_refresh_median_ms=${sorted_changes_times[$median_index]}"
  print "changes_refresh_mean_ms=$changes_mean"
  print "changes_refresh_p95_ms=${sorted_changes_times[$p95_index]}"
  print "changes_refresh_max_ms=${sorted_changes_times[-1]}"
  print "quick_open_runs=$runs"
  print "quick_open_min_ms=${sorted_quick_open_times[1]}"
  print "quick_open_median_ms=${sorted_quick_open_times[$median_index]}"
  print "quick_open_mean_ms=$quick_open_mean"
  print "quick_open_p95_ms=${sorted_quick_open_times[$p95_index]}"
  print "quick_open_max_ms=${sorted_quick_open_times[-1]}"
  if [[ -n "$ripgrep_executable" ]]; then
    print "repository_search_query=${FEATHER_PERF_SEARCH_QUERY:-import}"
    print "repository_search_runs=$runs"
    print "repository_search_min_ms=${sorted_search_times[1]}"
    print "repository_search_median_ms=${sorted_search_times[$median_index]}"
    print "repository_search_mean_ms=$search_mean"
    print "repository_search_p95_ms=${sorted_search_times[$p95_index]}"
    print "repository_search_max_ms=${sorted_search_times[-1]}"
  else
    print "repository_search=unavailable (ripgrep not installed)"
  fi
  if (( review_available )); then
    sorted_review_times=(${(f)"$(/usr/bin/sort -n "$review_timing_file")"})
    review_mean=$(/usr/bin/awk '{sum += $1} END {printf "%.3f", sum / NR}' "$review_timing_file")
    print "branch_review_base=$review_base"
    print "branch_review_runs=$runs"
    print "branch_review_min_ms=${sorted_review_times[1]}"
    print "branch_review_median_ms=${sorted_review_times[$median_index]}"
    print "branch_review_mean_ms=$review_mean"
    print "branch_review_p95_ms=${sorted_review_times[$p95_index]}"
    print "branch_review_max_ms=${sorted_review_times[-1]}"
  else
    print "branch_review=unavailable (no merge base with HEAD)"
  fi
fi
