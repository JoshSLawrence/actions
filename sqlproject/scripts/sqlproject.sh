#!/usr/bin/env bash
# The SQL project area's library: what the sqlproject/* scripts share, in
# sections: the project, publish profiles, Name=Value lists, SqlPackage
# arguments, running SqlPackage with a secret (a response file, never argv),
# authentication, deployment reports, deployment scripts and the plan's
# digest. Sourced after shared/scripts/common.sh:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=shared/scripts/common.sh
#   source "$SCRIPT_DIR/../../shared/scripts/common.sh"
#   # shellcheck source=sqlproject/scripts/sqlproject.sh
#   source "$SCRIPT_DIR/sqlproject.sh"
#
# A deployment is the project's dacpac x one publish profile
# (deployments/<name>.publish.xml). The profile names the server and the
# database; the deployment is named after the file. Everything that runs a
# tool goes through `mise exec`, scoped to the project's own mise.toml
# (cd_working_dir), so tools pinned anywhere else are never used.

# The owner of each deploy property the workflow's inputs control, so a
# profile or the properties input can't set it behind the caller's back
SQL_OWNED_PROPERTIES='{
  "blockonpossibledataloss": "allow-data-loss",
  "dropobjectsnotinsource": "deploy-mode",
  "donotdropobjecttypes": "keep-object-types (and deploy-mode)"
}'

# What truth mode keeps by default: what DBA tooling usually manages outside
# a project. "Do not drop" never stops the project's own users, roles or
# grants from deploying; it only keeps what others created.
export SQL_DEFAULT_KEEP_OBJECT_TYPES='Users;Logins;DatabaseRoles;ApplicationRoles;RoleMembership;ServerRoles;ServerRoleMembership;Permissions;Credentials;DatabaseScopedCredentials;MasterKeys'

# --- Project ------------------------------------------------------------------

# Print the name of the one *.sqlproj in the current directory
sql_find_project() {
  local -a projects=()
  local file
  for file in ./*.sqlproj; do
    [ -f "$file" ] && projects+=("${file#./}")
  done
  if [ ${#projects[@]} -eq 1 ]; then
    echo "${projects[0]}"
    return 0
  fi
  if [ ${#projects[@]} -eq 0 ]; then
    log_error "No *.sqlproj in ${PWD}. Point working-directory at the SQL project's folder (the one holding its .sqlproj)."
  else
    log_error "More than one SQL project in ${PWD}: ${projects[*]}. Put one SQL project per folder, or point working-directory at the project's folder."
  fi
  return 1
}

# --- Publish profiles -----------------------------------------------------------

# Print a publish profile as one JSON object:
#   {namespace, database, server, connection_keys, properties: {Name: value},
#    variables: {Name: value}}
# server is the data source of TargetConnectionString (Data Source, Server,
# Address, Addr or Network Address, any case; a tcp: prefix removed);
# connection_keys are the connection string's keys, lower-cased, so
# credentials can be refused without carrying their values around;
# properties are the PropertyGroup elements; variables are the profile's
# SqlCmdVariable items. A value may be an element with attributes. Fails,
# silently, if the file isn't well-formed XML.
# Usage: sql_profile_json "<file>"
sql_profile_json() {
  local json
  # Silent on failure: the caller says which profile it was
  json="$(mise exec -- yq -p xml -o json '.' "$1" 2> /dev/null)" || return 1
  jq -c '
    def arr: if type == "array" then . elif . == null then [] else [.] end;
    def text: (if type == "object" then (.["+content"] // "") else (. // "") end)
      | tostring | gsub("^\\s+|\\s+$"; "");
    def pairs: [ .[] | select(.key | startswith("+") | not) ];
    (.Project // {}) as $p
    | ([ $p.PropertyGroup | arr[] | objects | to_entries | pairs[] | {key, value: (.value | text)} ]
        | from_entries) as $props
    | ($props.TargetConnectionString // "" | split(";")
        | map(select(contains("=")) | {k: (split("=")[0] | gsub("^\\s+|\\s+$"; "") | ascii_downcase),
                                       v: (split("=")[1:] | join("=") | gsub("^\\s+|\\s+$"; ""))})) as $conn
    | ([ $conn[] | select(.k | IN("data source", "server", "address", "addr", "network address")) | .v ] | first // "") as $server
    | {
        namespace: ($p["+@xmlns"] // ""),
        database: ($props.TargetDatabaseName // ""),
        server: ($server | sub("^[Tt][Cc][Pp]:"; "")),
        connection_keys: ($conn | map(.k)),
        properties: $props,
        variables: ([ $p.ItemGroup | arr[] | objects | .SqlCmdVariable | arr[] | objects
                      | select(.["+@Include"] != null)
                      | {key: .["+@Include"], value: (.Value | text)} ] | from_entries)
      }' <<< "$json"
}

# Print what is wrong with a profile (from sql_profile_json), one line each.
# Usage: sql_profile_problems "<json>" "<file>"
sql_profile_problems() {
  jq -r --arg file "$2" --argjson owned "$SQL_OWNED_PROPERTIES" '
    def keys_in($names): [ .connection_keys[] | select(. as $k | $names | index($k)) ];
    ( if .namespace != "http://schemas.microsoft.com/developer/msbuild/2003" then "\($file): <Project> has no MSBuild namespace, and SqlPackage ignores the properties and SQLCMD variables of a profile without it. Add xmlns=\"http://schemas.microsoft.com/developer/msbuild/2003\" to <Project> (profiles made by Visual Studio and VS Code have it)." else empty end ),
    ( if .database == "" then "\($file): no TargetDatabaseName. Add <TargetDatabaseName> to the profile: it names the database this deployment publishes to." else empty end ),
    ( if .server == "" then "\($file): no server in TargetConnectionString. Add one, e.g. <TargetConnectionString>Data Source=myserver.database.windows.net;Encrypt=True</TargetConnectionString>." else empty end ),
    ( keys_in(["password", "pwd", "user id", "uid", "user", "authentication", "integrated security"])
      | if length > 0 then "\($file): TargetConnectionString has credentials (\(join(", "))). CI signs in with Entra ID; keep credentials out of profiles." else empty end ),
    ( .properties | keys[] | select(ascii_downcase | IN("targetuser", "targetpassword"))
      | "\($file): \(.) is set. CI signs in with Entra ID; keep credentials out of profiles." ),
    ( .properties | keys[] | ascii_downcase as $k | select($owned | has($k))
      | "\($file): \(.) is set, but the workflow owns it. Remove it from the profile; set the \($owned[$k]) input instead." ),
    ( .properties | to_entries[] | select((.key | ascii_downcase) == "createnewdatabase" and (.value | ascii_downcase) == "true")
      | "\($file): CreateNewDatabase is True, which drops and recreates the database. Remove it: this workflow never creates or recreates databases." ),
    ( [ .database, .server, (.properties | to_entries[] | .value), (.variables | to_entries[] | .value) ][]
      | select(contains("\"") or contains("\n") or contains("\r"))
      | "\($file): a value contains a double quote or a line break, which the workflow cannot pass to SqlPackage safely. Remove it from the profile." )
  ' <<< "$1" | sort -u
}

# --- Name=Value lists ---------------------------------------------------------

# Print what is wrong with a properties or variables input, one line each,
# without echoing values.
# Usage: sql_assignment_problems "<properties|variables>" "<text>"
sql_assignment_problems() {
  local kind="$1" text="$2" line name number=0
  while IFS= read -r line; do
    number=$((number + 1))
    name="${line%%=*}"
    if [[ "$line" != *=* ]] || ! [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
      echo "${kind}: entry ${number} isn't Name=Value (names start with a letter and hold letters, digits and underscores). Use one Name=Value per line."
      continue
    fi
    if [[ "$line" == *'"'* ]]; then
      echo "${kind}: ${name} has a double quote in its value, which the workflow cannot pass to SqlPackage safely. Remove it."
    fi
    if [ "$kind" = properties ] && jq -e --arg n "${name,,}" 'has($n)' <<< "$SQL_OWNED_PROPERTIES" > /dev/null; then
      echo "properties: ${name} is owned by the workflow. Set the $(jq -r --arg n "${name,,}" '.[$n]' <<< "$SQL_OWNED_PROPERTIES") input instead."
    fi
    if [ "$kind" = properties ] && [ "${name,,}" = createnewdatabase ]; then
      echo "properties: CreateNewDatabase drops and recreates the database; this workflow never does. Remove it."
    fi
  done < <(list_lines "$text")
}

# Print the Name=Value lines of a properties or variables input as a JSON
# object (later lines win). Fails, listing the problems, if any line is bad.
# Usage: sql_parse_assignments "<properties|variables>" "<text>"
sql_parse_assignments() {
  local kind="$1" text="$2" problems
  problems="$(sql_assignment_problems "$kind" "$text")"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do log_error "$line"; done <<< "$problems"
    return 1
  fi
  list_lines "$text" | jq -Rn '
    [ inputs | {key: (split("=")[0]), value: (split("=")[1:] | join("="))} ] | from_entries'
}

# --- SqlPackage arguments ---------------------------------------------------

# Print the arguments DeployReport, Script and Publish share, one per line,
# built only from the plan directory -- so what the plan reported is what the
# apply publishes. The deploy mode can be overridden: the "kept" report asks
# what truth mode would drop.
# Usage: sql_args "<plan dir>" "<additive|truth>"
sql_args() {
  local plan="$1" mode="$2" target="$1/deploy/target.json"
  local dacpac server database
  dacpac="$(jq -r .dacpac "$target")"
  server="$(jq -r '.server // empty' "$target")"
  database="$(jq -r .database "$target")"

  printf '%s\n' "/SourceFile:${plan}/deploy/dacpac/${dacpac}"
  printf '%s\n' "/Profile:${plan}/deploy/profile.publish.xml"
  if [ "$(jq -r .offline "$target")" = true ]; then
    printf '%s\n' "/TargetFile:${plan}/deploy/target.dacpac"
  else
    printf '%s\n' "/TargetServerName:${server}"
  fi
  printf '%s\n' "/TargetDatabaseName:${database}"

  if [ "$(jq -r .allow_data_loss "$target")" = true ]; then
    printf '%s\n' "/p:BlockOnPossibleDataLoss=False"
  else
    printf '%s\n' "/p:BlockOnPossibleDataLoss=True"
  fi
  if [ "$mode" = truth ]; then
    printf '%s\n' "/p:DropObjectsNotInSource=True"
    jq -r 'if (.keep_object_types | length) > 0 then "/p:DoNotDropObjectTypes=\(.keep_object_types | join(";"))" else empty end' "$target"
  else
    printf '%s\n' "/p:DropObjectsNotInSource=False"
  fi
  jq -r '.properties | to_entries[] | "/p:\(.key)=\(.value)"' "$target"
  jq -r '.variables | to_entries[] | "/v:\(.key)=\(.value)"' "$target"
}

# The arguments of the plan's own deploy mode
sql_common_args() {
  sql_args "$1" "$(jq -r .deploy_mode "$1/deploy/target.json")"
}

# The same, as truth mode: what the additive plan lists as kept
sql_kept_args() {
  sql_args "$1" truth
}

# --- Authentication -------------------------------------------------------------

# Print an Entra access token for Azure SQL from the az session. The caller
# masks it, outside the command substitution (the mask command is written to
# stdout): token="$(sql_access_token)"; mask_value "$token".
sql_access_token() {
  local token
  if ! token="$(mise exec -- az account get-access-token --resource https://database.windows.net/ --query accessToken --output tsv --only-show-errors)" || [ -z "$token" ]; then
    log_error "Couldn't get a token for Azure SQL. Check azure/login ran, and that the identity can sign in (a federated credential for this job's subject)."
    return 1
  fi
  printf '%s' "$token"
}

# --- Running SqlPackage ---------------------------------------------------------

# The private directory of the SqlPackage run in progress, so a script's EXIT
# trap can delete it should the run be interrupted (sql_cleanup_run)
SQL_RUN_DIR=""

sql_cleanup_run() {
  if [ -n "$SQL_RUN_DIR" ]; then
    rm -rf "$SQL_RUN_DIR"
    SQL_RUN_DIR=""
  fi
}

# Run SqlPackage with an action and arguments, and print its exit code's
# worth of output to the log file (scrubbed of the secret). Every argument
# goes into a response file (sqlpackage @file), one double-quoted line each,
# together with the secret -- the access token, or in SQL_AUTH=sql mode
# (local runs against a container only) SQL_USER and SQL_PASSWORD -- so no
# secret is ever on a command line. The file is mode 600 in a private temp
# directory, deleted afterwards. Quoting matters: SqlPackage echoes a
# malformed argument, secret included, so values with a double quote or line
# break are refused before they reach here.
#
# SQL_ONLINE=false (offline plans against a dacpac) adds no credentials.
# Returns SqlPackage's exit code.
# Usage: sql_run <action> <log file> <argument>...
sql_run() {
  local action="$1" log="$2" arg token="" secret="" rsp exit_code content
  shift 2

  SQL_RUN_DIR="$(umask 077 && mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sqlpackage.XXXXXX")" || {
    log_error "Couldn't create a private temp directory under ${RUNNER_TEMP:-${TMPDIR:-/tmp}}. Check the runner's disk and permissions."
    return 1
  }
  rsp="$SQL_RUN_DIR/args.rsp"
  (umask 077 && : > "$rsp")

  {
    printf '"%s"\n' "/Action:${action}"
    for arg in "$@"; do
      printf '"%s"\n' "$arg"
    done
  } >> "$rsp"

  if [ "${SQL_ONLINE:-true}" = true ]; then
    if [ "${SQL_AUTH:-entra}" = sql ]; then
      require_env SQL_USER "SQL_AUTH=sql is for local runs against a container: set SQL_USER and SQL_PASSWORD."
      require_env SQL_PASSWORD "SQL_AUTH=sql is for local runs against a container: set SQL_USER and SQL_PASSWORD."
      secret="$SQL_PASSWORD"
      mask_value "$secret"
      {
        printf '"%s"\n' "/TargetUser:${SQL_USER}"
        printf '"%s"\n' "/TargetPassword:${secret}"
        printf '"%s"\n' "/TargetTrustServerCertificate:True"
      } >> "$rsp"
    else
      if ! token="$(sql_access_token)"; then
        sql_cleanup_run
        return 1
      fi
      mask_value "$token"
      secret="$token"
      printf '"%s"\n' "/AccessToken:${secret}" >> "$rsp"
    fi
  fi

  log_cmd sqlpackage "/Action:${action}" "$@"
  set +e
  mise exec -- sqlpackage "@${rsp}" > "$log" 2>&1
  exit_code=$?
  set -e

  # SqlPackage echoes malformed arguments, so scrub the secret from its output
  if [ -n "$secret" ] && [ -s "$log" ]; then
    content="$(cat "$log"; printf x)"
    content="${content%x}"
    printf '%s' "${content//"$secret"/***}" > "$log"
  fi
  sed 's/^/  /' "$log"

  sql_cleanup_run
  return "$exit_code"
}

# --- Reports ----------------------------------------------------------------------

# Print a DeployReport as normalized JSON, so two reports compare with jq -S
# equality:
#   {alerts: [{name, issues: [..]}], operations: [{operation, items: [{value, type}]}]}
# yq returns a single child as an object and several as an array, and an
# absent or empty element as null or nothing: all become arrays, sorted.
# Usage: sql_report_json "<report.xml>"
sql_report_json() {
  local json
  if ! json="$(mise exec -- yq -p xml -o json '.' "$1" 2> /dev/null)"; then
    log_error "Couldn't read the SqlPackage report ${1}. Re-run the job; if it persists, report it at https://github.com/JoshSLawrence/actions/issues."
    return 1
  fi
  jq -cS '
    def arr: if type == "array" then . elif . == null then [] else [.] end;
    def child($name): if type == "object" then .[$name] else null end;
    (.DeploymentReport // {}) as $r
    | {
        alerts: ([ ($r | child("Alerts") | child("Alert") | arr)[] | objects
                   | {name: .["+@Name"],
                      issues: ([ (.Issue | arr)[] | objects | .["+@Value"] ] | sort)} ]
                 | sort_by(.name)),
        operations: ([ ($r | child("Operations") | child("Operation") | arr)[] | objects
                       | {operation: .["+@Name"],
                          items: ([ (.Item | arr)[] | objects
                                    | {value: .["+@Value"], type: .["+@Type"]} ]
                                  | sort_by(.value, .type))} ]
                     | sort_by(.operation))
      }' <<< "$json"
}

# Print the possible-data-loss issues of a normalized report, one per line
sql_data_loss() {
  jq -r '.alerts[] | select(.name == "DataIssue") | .issues[]' <<< "$1"
}

# Succeed if a generated script would create the database: the target
# doesn't exist (a report does not show it, but the script does)
# Usage: sql_missing_database "<script.sql>"
sql_missing_database() {
  grep -Eq '^CREATE DATABASE \[\$\(DatabaseName\)\]' "$1"
}

# Print "<operation>: <object>" for every item of a normalized report
sql_report_lines() {
  jq -r '.operations[] | .operation as $o | .items[] | "\($o) \(.value) (\(.type))"' <<< "$1"
}

# --- Deployment scripts -----------------------------------------------------------

# Print the SHA-256 of one file inside a dacpac (a zip), or nothing if the
# dacpac lacks it. Usage: sql_dacpac_member_sha256 "<dacpac>" "<member>"
sql_dacpac_member_sha256() {
  local tmp
  tmp="$(mktemp)"
  if unzip -p "$1" "$2" > "$tmp" 2> /dev/null; then
    file_sha256 "$tmp"
  fi
  rm -f "$tmp"
}

# Print the dacpac's pre- and post-deployment scripts as
# {pre_sha256, post_sha256}, null for a script it doesn't have. They do not
# show in a deployment report, so a change to them has to be found here.
# Usage: sql_dacpac_scripts "<dacpac>"
sql_dacpac_scripts() {
  local pre post
  pre="$(sql_dacpac_member_sha256 "$1" predeploy.sql)"
  post="$(sql_dacpac_member_sha256 "$1" postdeploy.sql)"
  jq -cn --arg pre "$pre" --arg post "$post" \
    '{pre_sha256: (if $pre == "" then null else $pre end), post_sha256: (if $post == "" then null else $post end)}'
}

# --- The plan's digest -------------------------------------------------------------

# Print a plan's SHA-256: the digest of deploy/, which holds everything the
# apply publishes. Usage: sql_plan_sha256 "<plan dir>"
sql_plan_sha256() {
  dir_sha256 "$1/deploy"
}

# Fail unless a plan directory is there and matches the plan job's digest.
# PLAN_SHA256 is required in GitHub Actions.
# Usage: sql_verify_plan "<plan dir>"
sql_verify_plan() {
  local plan_dir="$1" actual
  if [ ! -f "$plan_dir/deploy/target.json" ]; then
    log_error "No plan at ${plan_dir}/deploy. Plan artifacts expire (plan-retention-days); re-run the whole workflow to plan again."
    return 1
  fi
  if is_github_actions; then
    require_env PLAN_SHA256 "It comes from the plan job's plan-sha256 output; check the workflow passes it to the apply action."
  fi
  if [ -n "${PLAN_SHA256:-}" ]; then
    actual="$(sql_plan_sha256 "$plan_dir")"
    if [ "$actual" != "$PLAN_SHA256" ]; then
      log_error "The plan's sha256 is ${actual}, but the plan job produced ${PLAN_SHA256}. Refusing to publish a plan that isn't the one that was reviewed; re-run the whole workflow."
      return 1
    fi
    log_success "Plan matches the reviewed plan (sha256 ${PLAN_SHA256})"
  fi
}
