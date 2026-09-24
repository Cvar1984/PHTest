#!/usr/bin/env bash
# phtest wizard: add / remove / config / build / start / stop / open / cleanup
#
# "config" toggles blocked functions (by category or one by one), ini flags
# (allow_url_fopen ...), or applies a preset (strict / shell-only / open).
#
#   ./wizard.sh                      interactive menu (fzf if installed, numbered menus otherwise)
#   ./wizard.sh ACTION [VERSION...]  one-shot, e.g. ./wizard.sh start 4.1.2 8.5.6
#                                    VERSION may be "all"; ACTION also accepts "status"
#
# Versions live in versions.list (version|type|configure flags). "legacy" versions are
# compiled from source via docker/Dockerfile, "official" ones use php:<ver>-apache.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

DOCKER=${DOCKER:-docker}
REGISTRY=versions.list
LEGACY_FLAGS_DEFAULT="--enable-cgi --without-mysql --with-zlib"

say()  { echo "==> $*"; }
warn() { echo "warn: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

confirm() { local a; read -rp "$1 [y/N] " a; [[ $a =~ ^[Yy] ]]; }

# ── registry ────────────────────────────────────────────────────────────────
seed_registry() {
  [ -f "$REGISTRY" ] && return
  cat > "$REGISTRY" <<'EOF'
# version|type|configure flags (legacy only)
4.1.2|legacy|--enable-cgi --without-mysql --without-zlib
4.2.3|legacy|--enable-cgi --without-mysql --without-zlib
4.3.0|legacy|--enable-cgi --without-mysql --with-zlib
4.3.11|legacy|--enable-cgi --without-mysql --with-zlib
5.0.5|legacy|--enable-cgi --with-zlib --disable-libxml --disable-dom --disable-simplexml --disable-xml --without-pear
7.4.33|official|
8.5.6|official|
EOF
}

versions() { grep -v '^#' "$REGISTRY" | cut -d'|' -f1; }
field()    { awk -F'|' -v v="$1" -v n="$2" '$1==v {print $n}' "$REGISTRY"; }
has_version() { versions | grep -Fxq "$1"; }

# 8 + major + minor + last digit of patch  (4.1.2 -> 8412, 7.4.33 -> 8743)
port_for() { local IFS=.; set -- $1; echo "8$1$2${3: -1}"; }

image_of()  { [ "$(field "$1" 2)" = official ] && echo "php:$1-apache" || echo "phtest-php:$1"; }
ini_path()  { [ "$(field "$1" 2)" = official ] && echo /usr/local/etc/php/php.ini || echo /usr/local/lib/php.ini; }
image_exists() { $DOCKER image inspect "$(image_of "$1")" >/dev/null 2>&1; }
state()     { $DOCKER inspect -f '{{.State.Status}}' "phtest-$1" 2>/dev/null || echo none; }

state_label() {
  local s; s=$(state "$1")
  if [ "$s" = none ]; then image_exists "$1" && echo "no container" || echo "not built"; else echo "$s"; fi
}

status_table() {
  local v
  printf '\n%-9s %-9s %-6s %-8s %s\n' VERSION TYPE PORT BLOCKED STATE
  for v in $(versions); do
    printf '%-9s %-9s %-6s %-8s %s\n' "$v" "$(field "$v" 2)" "$(port_for "$v")" \
      "$(get_blocked "$v" 2>/dev/null | wc -l)" "$(state_label "$v")"
  done
  echo
}

# ── pickers: fzf when available, plain numbered menus otherwise ─────────────
have_fzf() { [ -z "${PHTEST_NO_FZF:-}" ] && command -v fzf >/dev/null; }

pick_one() {   # pick_one PROMPT ITEM...  -> chosen item on stdout (empty = cancelled)
  local prompt=$1; shift
  if have_fzf; then
    printf '%s\n' "$@" | fzf --prompt="$prompt > " --height=40% --reverse
  else
    local PS3="$prompt (number): " c
    select c in "$@"; do [ -n "$c" ] && { echo "$c"; return; }; done
  fi
}

pick_many() {  # pick_many PROMPT ITEM...  -> chosen items, one per line
  local prompt=$1; shift
  if have_fzf; then
    printf '%s\n' "$@" | fzf -m --prompt="$prompt (TAB = multi-select) > " --height=40% --reverse
  else
    local -a items=("$@"); local i n
    for i in "${!items[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${items[i]}" >&2; done
    read -rp "$prompt (numbers, 'a' = all): " n
    if [ "$n" = a ]; then printf '%s\n' "${items[@]}"; return; fi
    for i in $n; do
      [[ $i =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#items[@]}" ] && echo "${items[i-1]}"
    done
  fi
}

ARGS=()   # versions given on the command line (one-shot mode)

targets() {    # targets PROMPT -> versions to act on, one per line
  local v
  if [ ${#ARGS[@]} -gt 0 ]; then
    if [ "${ARGS[0]}" = all ]; then versions; return; fi
    for v in "${ARGS[@]}"; do has_version "$v" && echo "$v" || warn "unknown version: $v"; done
    return
  fi
  local -a items=()
  for v in $(versions); do
    items+=("$(printf '%-8s %-9s :%-5s %s' "$v" "$(field "$v" 2)" "$(port_for "$v")" "$(state_label "$v")")")
  done
  pick_many "$1" "${items[@]}" | awk '{print $1}'
}

run_on() {     # run_on FUNC PROMPT
  local fn=$1 list v
  list=$(targets "$2")
  [ -z "$list" ] && { say "nothing selected"; return; }
  for v in $list; do "$fn" "$v"; done
}

# ── php.ini config: blocked functions + flags ───────────────────────────────
# category|functions
CATALOG=(
  "shell|exec shell_exec system passthru popen proc_open proc_close proc_get_status proc_nice proc_terminate"
  "process|pcntl_exec pcntl_fork pcntl_signal pcntl_wait pcntl_waitpid posix_kill posix_mkfifo posix_setuid posix_setgid posix_seteuid posix_setegid posix_setsid posix_setpgid"
  "env|putenv dl ini_alter ini_restore"
  "filesystem|symlink link"
  "network|fsockopen pfsockopen stream_socket_client stream_socket_server curl_exec curl_multi_exec curl_init"
  "apache|apache_child_terminate apache_setenv"
  "recon|show_source highlight_file posix_uname"
  "logging|syslog openlog closelog"
)
FLAGS=(allow_url_fopen allow_url_include expose_php display_errors)
CFG_DIRTY=0   # set when a php.ini was changed, so config_one can offer a restart

ini_file()     { echo "conf/$1/php.ini"; }
flag_default() { case $1 in allow_url_include) echo Off ;; *) echo On ;; esac; }
flag_on()      { case "${1,,}" in off|0|false|no|"") return 1 ;; *) return 0 ;; esac; }

cat_names() { local row; for row in "${CATALOG[@]}"; do echo "${row%%|*}"; done; }
cat_funcs() { local row; for row in "${CATALOG[@]}"; do [ "${row%%|*}" = "$1" ] && echo "${row#*|}" | tr ' ' '\n'; done; }
all_funcs() { local c; for c in $(cat_names); do cat_funcs "$c"; done; }
func_cat()  { local row; for row in "${CATALOG[@]}"; do case " ${row#*|} " in *" $1 "*) echo "${row%%|*}"; return ;; esac; done; echo custom; }

get_blocked() {   # one blocked function per line
  awk '/^[ \t]*disable_functions[ \t]*=/ { sub(/^[^=]*=/, ""); sub(/;.*/, ""); gsub(/[ \t]/, ""); print; exit }' \
    "$(ini_file "$1")" | tr ',' '\n' | sed '/^$/d'
}

get_flag() {      # get_flag VERSION KEY -> value, or the PHP default when unset
  local val
  val=$(awk -v k="$2" '$0 ~ "^[ \t]*" k "[ \t]*=" { sub(/^[^=]*=/, ""); sub(/;.*/, ""); gsub(/[ \t]/, ""); print; exit }' "$(ini_file "$1")")
  echo "${val:-$(flag_default "$2")}"
}

# Replace the first "KEY = ..." line (append if absent). Rewrites in place so the bind-mounted
# inode stays the same. The first write also drops the stale "strict hosting" comment block.
set_ini() {       # set_ini FILE KEY VALUE
  local f=$1 tmp; tmp=$(mktemp)
  awk -v k="$2" -v val="$3" '
    /^; "strict hosting" profile/ { skip = 1; print "; disable_functions and the flags below are managed by ./wizard.sh config"; next }
    skip && /^[ \t]*disable_functions[ \t]*=/ { skip = 0 }
    skip { next }
    $0 ~ "^[ \t]*" k "[ \t]*=" && !done { print k " = " val; done = 1; next }
    { print }
    END { if (!done) print k " = " val }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
  CFG_DIRTY=1
}

set_blocked() {   # set_blocked VERSION < one function per line
  local csv; csv=$(awk '!seen[$0]++' | paste -sd, -)
  set_ini "$(ini_file "$1")" disable_functions "$csv"
}

set_funcs() {     # set_funcs VERSION block|allow FUNC...
  local v=$1 mode=$2; shift 2
  { get_blocked "$v" | grep -vxF -f <(printf '%s\n' "$@"); [ "$mode" = block ] && printf '%s\n' "$@"; } | set_blocked "$v"
}

flip_funcs() {    # flip_funcs VERSION FUNC...
  local v=$1 f; shift
  for f in "$@"; do
    if get_blocked "$v" | grep -qxF "$f"; then set_funcs "$v" allow "$f"; else set_funcs "$v" block "$f"; fi
  done
}

cat_state() {     # cat_state VERSION CATEGORY -> x (all blocked), ~ (some), space (none)
  local n=0 t=0 f blocked; blocked=$(get_blocked "$1")
  for f in $(cat_funcs "$2"); do t=$((t + 1)); grep -qxF "$f" <<<"$blocked" && n=$((n + 1)); done
  if [ "$n" -eq "$t" ]; then echo x; elif [ "$n" -gt 0 ]; then echo '~'; else echo ' '; fi
}

apply_preset() {  # apply_preset VERSION strict|shell-only|open
  local v=$1 f fopen=On expose=On; f=$(ini_file "$v")
  case $2 in
    strict)     all_funcs | set_blocked "$v"; fopen=Off; expose=Off ;;
    shell-only) cat_funcs shell | set_blocked "$v" ;;
    open)       printf '' | set_blocked "$v" ;;
  esac
  set_ini "$f" allow_url_fopen "$fopen"
  set_ini "$f" allow_url_include Off
  set_ini "$f" expose_php "$expose"
}

new_ini() {       # new_ini VERSION PRESET -> writes conf/VERSION/php.ini from scratch
  mkdir -p "conf/$1"
  cat > "$(ini_file "$1")" <<EOF
; php.ini for phtest-$1, managed by ./wizard.sh config
; restart to apply: docker restart phtest-$1
disable_functions =
allow_url_fopen = On
allow_url_include = Off
expose_php = On
display_errors = On
EOF
  apply_preset "$1" "$2"
}

show_config() {
  local v=$1 k
  printf '\n── %s: %s functions blocked ──\n' "$v" "$(get_blocked "$v" | wc -l)"
  get_blocked "$v" | paste -sd' ' - | fold -s -w 76 | sed 's/^/  /'
  for k in "${FLAGS[@]}"; do printf '  %-18s %s\n' "$k" "$(get_flag "$v" "$k")"; done
  echo
}

toggle_categories() {
  local v=$1 c s picked; local -a items=()
  for c in $(cat_names); do
    case $(cat_state "$v" "$c") in x) s=blocked ;; '~') s=partial ;; *) s=allowed ;; esac
    items+=("$(printf '%-11s %-8s %s functions' "$c" "$s" "$(cat_funcs "$c" | wc -l)")")
  done
  picked=$(pick_many "Toggle categories on $v" "${items[@]}" | awk '{print $1}')
  for c in $picked; do   # anything not fully blocked becomes fully blocked; fully blocked becomes allowed
    if [ "$(cat_state "$v" "$c")" = x ]; then set_funcs "$v" allow $(cat_funcs "$c"); else set_funcs "$v" block $(cat_funcs "$c"); fi
  done
}

toggle_functions() {
  local v=$1 f s blocked list picked; local -a items=()
  blocked=$(get_blocked "$v")
  list=$( { all_funcs; printf '%s\n' "$blocked" | grep -vxF -f <(all_funcs); } | sed '/^$/d' | awk '!seen[$0]++')
  for f in $list; do
    grep -qxF "$f" <<<"$blocked" && s=blocked || s=allowed
    items+=("$(printf '%-24s %-8s (%s)' "$f" "$s" "$(func_cat "$f")")")
  done
  picked=$(pick_many "Toggle functions on $v" "${items[@]}" | awk '{print $1}')
  [ -n "$picked" ] && flip_funcs "$v" $picked
}

toggle_flags() {
  local v=$1 k val picked; local -a items=()
  for k in "${FLAGS[@]}"; do
    flag_on "$(get_flag "$v" "$k")" && val=On || val=Off
    items+=("$(printf '%-18s %s' "$k" "$val")")
  done
  picked=$(pick_many "Flip flags on $v" "${items[@]}" | awk '{print $1}')
  for k in $picked; do
    if flag_on "$(get_flag "$v" "$k")"; then set_ini "$(ini_file "$v")" "$k" Off; else set_ini "$(ini_file "$v")" "$k" On; fi
  done
}

block_custom() {
  local f; read -rp "Function name to block: " f
  [[ $f =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "not a valid function name"; return 1; }
  set_funcs "$1" block "$f"
}

config_one() {
  local v=$1 c p
  [ -f "$(ini_file "$v")" ] || { warn "$(ini_file "$v") is missing"; return 1; }
  CFG_DIRTY=0
  show_config "$v"
  while :; do
    c=$(pick_one "Configure $v" "toggle categories" "toggle functions" "toggle ini flags" \
        "block custom function" "apply preset" "show current" "done")
    case $c in
      "toggle categories")      toggle_categories "$v" ;;
      "toggle functions")       toggle_functions "$v" ;;
      "toggle ini flags")       toggle_flags "$v" ;;
      "block custom function")  block_custom "$v" ;;
      "apply preset")
        p=$(pick_one "Preset" "strict (everything blocked, remote download off)" \
            "shell-only (exec family blocked)" "open (nothing blocked)"); p=${p%% *}
        [ -n "$p" ] && confirm "Replace $v's blocked list with the '$p' preset?" && apply_preset "$v" "$p" ;;
      "show current") ;;
      *) break ;;
    esac
    show_config "$v"
  done
  if [ "$CFG_DIRTY" = 1 ] && [ "$(state "$v")" = running ]; then
    confirm "Restart phtest-$v to apply the changes?" && $DOCKER restart "phtest-$v" >/dev/null && say "restarted $v"
  fi
}

# ── actions ─────────────────────────────────────────────────────────────────
build_one() {
  local v=$1
  if [ "$(field "$v" 2)" = official ]; then
    say "pulling php:$v-apache"
    $DOCKER pull "php:$v-apache" >/dev/null && say "pulled $v" || warn "pull failed for $v"
  else
    say "building phtest-php:$v (compiles PHP from source, expect several minutes)"
    $DOCKER build -f docker/Dockerfile -t "phtest-php:$v" \
      --build-arg PHP_SERIES="${v%%.*}" --build-arg PHP_VERSION="$v" \
      --build-arg CONFIGURE_FLAGS="$(field "$v" 3)" docker \
      && say "built $v" || warn "build failed for $v"
  fi
}

start_one() {
  local v=$1
  case $(state "$v") in
    running) say "$v already running on :$(port_for "$v")"; return ;;
    none) ;;
    *) $DOCKER start "phtest-$v" >/dev/null && say "started $v on :$(port_for "$v")"; return ;;
  esac
  image_exists "$v" || { say "no image for $v yet"; build_one "$v"; image_exists "$v" || return 1; }
  [ -f "conf/$v/php.ini" ] || { warn "conf/$v/php.ini is missing"; return 1; }
  mkdir -p www
  $DOCKER run -d --name "phtest-$v" -p "$(port_for "$v"):80" \
    -v "$PWD/www:/var/www/html" -v "$PWD/conf/$v/php.ini:$(ini_path "$v")" \
    "$(image_of "$v")" >/dev/null \
    && say "started $v on :$(port_for "$v")" || warn "could not start $v"
}

stop_one() {
  [ "$(state "$1")" = running ] || { say "$1 is not running"; return; }
  $DOCKER stop "phtest-$1" >/dev/null && say "stopped $1"
}

open_one() {
  local url="http://localhost:$(port_for "$1")/"
  [ "$(state "$1")" = running ] || { warn "$1 is not running, start it first"; return; }
  say "$url"
  command -v xdg-open >/dev/null && xdg-open "$url" >/dev/null 2>&1 &
}

add_version() {
  local v t flags base src p x
  read -rp "New version (X.Y.Z): " v
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "expected X.Y.Z"; return 1; }
  has_version "$v" && { warn "$v is already registered"; return 1; }
  p=$(port_for "$v")
  for x in $(versions); do
    [ "$(port_for "$x")" = "$p" ] && { warn "port $p is already used by $x"; return 1; }
  done

  t=$(pick_one "Type" official legacy); [ -z "$t" ] && return 1
  flags=""
  if [ "$t" = legacy ]; then
    [ "${v%%.*}" -le 5 ] || { warn "legacy builds fetch from museum.php.net, which only hosts PHP 5 and older; use official"; return 1; }
    read -rp "configure flags [$LEGACY_FLAGS_DEFAULT]: " flags
    flags=${flags:-$LEGACY_FLAGS_DEFAULT}
  fi

  src=$(pick_one "Initial php.ini" "strict (everything blocked, remote download off)" \
        "shell-only (exec family blocked)" "open (nothing blocked)" "copy (duplicate another version's php.ini)")
  src=${src%% *}; [ -z "$src" ] && return 1
  if [ "$src" = copy ]; then
    base=$(pick_one "Copy php.ini from" $(versions)); [ -z "$base" ] && return 1
    mkdir -p "conf/$v"
    sed "s/phtest-[A-Za-z0-9.]*/phtest-$v/g" "conf/$base/php.ini" > "conf/$v/php.ini"
  else
    new_ini "$v" "$src"
  fi
  echo "$v|$t|$flags" >> "$REGISTRY"
  say "added $v ($t) on :$p, php.ini: $src"
  confirm "Fine-tune the blocked functions now?" && config_one "$v"
  confirm "Build/pull it now?" && build_one "$v"
}

remove_one() {
  local v=$1
  confirm "Remove $v (container, image, registry entry)?" || { say "kept $v"; return; }
  $DOCKER rm -f "phtest-$v" >/dev/null 2>&1
  [ "$(field "$v" 2)" = legacy ] && $DOCKER rmi "phtest-php:$v" >/dev/null 2>&1
  awk -F'|' -v v="$v" '$1 != v' "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  say "removed $v"
  if [ -d "conf/$v" ] && confirm "Also delete conf/$v/?"; then rm -r "conf/$v"; fi
}

cleanup() {
  local stopped img n=0
  stopped=$($DOCKER ps -a --filter name=phtest- --filter status=exited --filter status=created --format '{{.Names}}')
  if [ -n "$stopped" ]; then
    echo "Stopped containers:"; echo "$stopped" | sed 's/^/  /'
    confirm "Remove them? (images and conf are kept)" && echo "$stopped" | xargs $DOCKER rm >/dev/null && say "containers removed"
  else
    say "no stopped phtest containers"
  fi
  if confirm "Prune dangling docker images? (leftovers from rebuilds, but this is system-wide, not just phtest)"; then
    $DOCKER image prune -f | tail -1
  fi
  if confirm "Also delete built phtest-php:* images no container uses? (rebuilding takes minutes)"; then
    for img in $($DOCKER images --format '{{.Repository}}:{{.Tag}}' | grep '^phtest-php:'); do
      $DOCKER rmi "$img" >/dev/null 2>&1 && { say "removed $img"; n=$((n + 1)); }
    done
    [ "$n" -eq 0 ] && say "nothing removable (images still in use, or none built)"
  fi
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  $DOCKER info >/dev/null 2>&1 || die "cannot reach the docker daemon ($DOCKER info failed)"
  seed_registry

  local action=${1:-} oneshot=0
  if [ -n "$action" ]; then oneshot=1; shift; ARGS=("$@"); fi

  while :; do
    if [ -z "$action" ]; then
      status_table
      action=$(pick_one "Action" add remove config build start stop open cleanup quit)
    fi
    case ${action:-quit} in
      add)     add_version ;;
      remove)  run_on remove_one "Remove" ;;
      config)  run_on config_one "Configure" ;;
      build)   run_on build_one  "Build / pull" ;;
      start)   run_on start_one  "Start" ;;
      stop)    run_on stop_one   "Stop" ;;
      open)    run_on open_one   "Open in browser" ;;
      cleanup) cleanup ;;
      status)  status_table ;;
      quit|q)  break ;;
      *)       die "unknown action: $action (add remove config build start stop open cleanup status)" ;;
    esac
    [ "$oneshot" = 1 ] && break
    action=""
  done
}

main "$@"
