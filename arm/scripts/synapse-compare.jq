# Compares a Synapse template's artifacts with their live definitions, as
# the deployer (JoshSLawrence/synapse-deploy) would publish them. Run with
# jq -n -f, from arm_synapse_compare in arm.sh:
#
#   $template[0]    the plan's (stripped) TemplateForWorkspace.json
#   $parameters[0]  an ARM parameters file: the plan's parameters plus
#                   parameter-secrets (a scratch file, never the plan's)
#   $entries        the template's artifacts as plan.sh keys them, in the
#                   template's order: {type, name, key, default}
#   $live           arm_live_lines output with ARM_LIVE_PROPERTIES=true:
#                   {type, name, etag, properties}
#   $workspace      the target workspace's name
#   $managed        property names the service sets itself (JSON array)
#
# Prints one compact object per template artifact:
#   {key, status, paths: [{path, change, why?}]}
# status: skipped | create | modify | unchanged | unknown | secure
# change: modified | added | removed | secure (a secure value differs) |
#         not-compared (secure, and the service hides it) | unknown
# Values are never printed: only paths.

# --- The deployer's expressions (src/expression.ts) -------------------------
#
# A string is an expression when all of it is "[...]", it parses, and the
# outer call is parameters, variables, concat or resourceId; one that opens
# like a supported call but doesn't parse fails the deployment. Anything
# else is literal text: "[[" is NOT an escape here (the deployer sends it
# as it is), unlike in an ARM deployment.

def tokens: [scan("'(?:[^']|'')*'|-?[0-9]+|[A-Za-z][A-Za-z0-9]*|[(),]|\\S")];

def pexpr:
  .t[.i] as $tok
  | if $tok == null then error("parse")
    elif ($tok | startswith("'")) then
      if ($tok | length) < 2 or ($tok | endswith("'") | not) then error("parse")
      else .node = {s: ($tok[1:-1] | gsub("''"; "'"))} | .i += 1 end
    elif ($tok | test("^-?[0-9]+$")) then .node = {n: ($tok | tonumber)} | .i += 1
    elif ($tok | test("^[A-Za-z]")) then
      if .t[.i + 1] != "(" then error("parse") else . end
      | .i += 2
      | if .t[.i] == ")" then .node = {f: ($tok | ascii_downcase), a: []} | .i += 1
        else
          def args($acc):
            pexpr
            | ($acc + [.node]) as $next
            | if .t[.i] == "," then .i += 1 | args($next)
              elif .t[.i] == ")" then .i += 1 | .node = {f: ($tok | ascii_downcase), a: $next}
              else error("parse") end;
          args([])
        end
    else error("parse") end;

def supported: IN("parameters", "variables", "concat", "resourceid");
def all_supported: if has("f") then (.f | supported) and all(.a[]; all_supported) else true end;

# "literal", "invalid" or {expr: <node>}
def classify:
  if (startswith("[") and endswith("]")) | not then "literal"
  else
    (try ({t: (.[1:-1] | tokens), i: 0} | pexpr | if .i != (.t | length) then error("parse") else .node end) catch null) as $node
    | if $node == null then
        (if test("^\\[\\s*(parameters|variables|concat|resourceid)\\s*\\("; "i") then "invalid" else "literal" end)
      elif ($node | has("f") | not) or ($node.f | supported | not) then "literal"
      elif ($node | all_supported | not) then "invalid"
      else {expr: $node} end
  end;

# What the plan can't see as a plain value
def unknown($why): {"__plan": "unknown", why: $why};
def secure($v): {"__plan": "secure", value: $v};
def is_unknown: type == "object" and .__plan == "unknown";
def is_secure: type == "object" and .__plan == "secure";
def marked: is_unknown or is_secure;

def find($obj; $name): $obj | to_entries | map(select(.key | ascii_downcase == ($name | ascii_downcase))) | first;

def is_secure_type: (.type // "string") | ascii_downcase | IN("securestring", "secureobject");

# Evaluates every string of a value as the deployer does. Parameters follow
# its Scope (src/template.ts): workspaceName is the target; a supplied value
# is used as it is; a default is evaluated. A secure parameter's value is
# wrapped, so it is compared but never shown. param and evalnode are nested
# so the three can call one another: jq has no forward declarations.
def evaluate($depth):
  def param($name; $depth):
    find($template[0].parameters // {}; $name) as $declared
    | find($parameters[0].parameters // {}; $name) as $given
    | if ($name | ascii_downcase) == "workspacename" then $workspace
      elif $declared == null then unknown("the template has no parameter \($name)")
      elif $depth > 10 then unknown("parameter \($name) refers to itself")
      else
        (if $given != null and ($given.value | has("value")) then $given.value.value
         elif $given != null then unknown("parameter \($name) is a Key Vault reference")
         elif ($declared.value | has("defaultValue")) then ($declared.value.defaultValue | evaluate($depth + 1))
         else unknown("no value for parameter \($name)") end)
        | if is_unknown or ($declared.value | is_secure_type | not) then . else secure(.) end
      end;
  def evalnode($depth):
    if has("s") then .s
    elif has("n") then .n
    else
      [.a[] | evalnode($depth)] as $args
      | if (.f == "parameters" or .f == "variables") and (($args | length) != 1 or ($args[0] | type) != "string") then
          unknown("\(.f)() takes one name")
        elif .f == "parameters" then param($args[0]; $depth)
        elif .f == "variables" then
          find($template[0].variables // {}; $args[0]) as $v
          | if $v == null then unknown("the template has no variable \($args[0])") else ($v.value | evaluate($depth + 1)) end
        elif .f == "concat" and ($args | length) == 0 then unknown("concat() needs an argument")
        elif .f == "concat" then
          if any($args[]; is_unknown) then first($args[] | select(is_unknown))
          else
            ($args | map(if is_secure then .value else . end)) as $plain
            | if all($plain[]; type == "string" or (type == "number" and . == floor)) then
                ($plain | map(tostring) | join("")) | if any($args[]; is_secure) then secure(.) else . end
              else unknown("concat() of something other than strings and integers") end
          end
        else unknown("resourceId() outside a name or dependsOn") end
    end;

  if type == "string" then
    classify as $c
    | if $c == "literal" then .
      elif $c == "invalid" then unknown("an expression the deployer can't evaluate")
      else ($c.expr | evalnode($depth)) end
  elif type == "array" then map(evaluate($depth))
  elif type == "object" then map_values(evaluate($depth))
  else . end;

# --- The deployer's default names (src/defaults.ts) ------------------------
#
# A LinkedServiceReference to another workspace's default linked service
# (<source>-WorkspaceDefaultStorage, ...SqlServer) is published as the
# target's.

def remap_name:
  (capture("^(?<w>.+)-WorkspaceDefault(?<s>Storage|SqlServer)$"; "i") // null) as $m
  | if $m == null or ($m.w | ascii_downcase) == ($workspace | ascii_downcase) then .
    else "\($workspace)-WorkspaceDefault\(if ($m.s | ascii_downcase) == "storage" then "Storage" else "SqlServer" end)" end;

# remapDependency: the last segment of a dependsOn string, when the segment
# before it is linkedServices (a pipeline named like a default keeps its name)
def remap_dependency:
  if contains("/") then
    rindex("/") as $i
    | if (.[:$i] | split("/") | last | ascii_downcase) == "linkedservices"
      then .[:$i + 1] + (.[$i + 1:] | remap_name)
      else . end
  else . end;

def remap_references:
  if type == "array" then map(remap_references)
  elif type == "object" and (marked | not) then
    . as $o
    | with_entries(
        if .key == "referenceName" and (.value | type) == "string" and $o.type == "LinkedServiceReference"
        then .value |= remap_name
        elif .key == "dependsOn" and (.value | type) == "array"
        then .value |= map(if type == "string" then remap_dependency else remap_references end)
        else .value |= remap_references end)
  else . end;

# --- Normalization ---------------------------------------------------------
#
# Each rule is something the service adds, drops or rewrites (measured on
# real workspaces; see docs/design/arm-live-comparison.md). Applied to both
# sides.

def tidy:
  if type == "object" and (marked | not) then
    with_entries(select(.value != null) | .value |= tidy | select(.value != [] and .value != {}))
  elif type == "array" then map(tidy)
  else . end;

def normalize($kind):
  tidy
  | reduce $managed[] as $p (.; del(.[$p]))
  | if $kind == "notebooks" then
      del(.metadata.kernelspec, .metadata.a365ComputeOptions)
      | if .sessionProperties.runAsWorkspaceSystemIdentity == false then del(.sessionProperties.runAsWorkspaceSystemIdentity) else . end
    else . end
  | tidy;

# --- Differences -----------------------------------------------------------

def segment: if type == "number" then "[\(.)]" elif test("^[A-Za-z_$][A-Za-z0-9_$]*$") then ".\(.)" else "[\(tojson)]" end;
# The display path: under properties, without trailing array indexes (a line
# of a cell's source is reported as the source)
def show: (. as $p | [range(0; length) | select(($p[.:] | all(type == "number")) | not) | $p[.]]) | "properties" + (map(segment) | join(""));

def hidden: . == null or (type == "string" and test("^\\*+$"));

def diff($a; $b; $p):
  if ($a | is_unknown) then {path: $p, change: "unknown", why: $a.why}
  elif ($a | is_secure) then
    if ($b | hidden) then {path: $p, change: "not-compared"}
    elif ($a.value | tidy) == ($b | tidy) then empty
    else {path: $p, change: "secure"} end
  elif ($a | type) == "object" and ($b | type) == "object" then
    (($a | keys) + ($b | keys) | unique)[] as $k
    | if ($a | has($k)) and ($b | has($k)) then diff($a[$k]; $b[$k]; $p + [$k])
      elif ($a | has($k)) then
        (if ($a[$k] | is_unknown) then {path: ($p + [$k]), change: "unknown", why: $a[$k].why}
         elif ($a[$k] | is_secure) then {path: ($p + [$k]), change: "not-compared"}
         elif ($a[$k] | any(.. ; type == "object" and .__plan == "unknown")) then
           {path: ($p + [$k]), change: "unknown", why: ([$a[$k] | .. | select(type == "object" and .__plan == "unknown") | .why] | first)}
         elif ($a[$k] | any(.. ; type == "object" and .__plan == "secure")) then
           {path: ($p + [$k]), change: "not-compared"}
         else {path: ($p + [$k]), change: "added"} end)
      else {path: ($p + [$k]), change: "removed"} end
  elif ($a | type) == "array" and ($b | type) == "array" and ($a | length) == ($b | length) then
    range(0; $a | length) as $i | diff($a[$i]; $b[$i]; $p + [$i])
  elif $a == $b then empty
  else {path: $p, change: "modified"} end;

# --- Main ------------------------------------------------------------------

["notebooks", "sparkjobdefinitions", "sqlscripts", "kqlscripts", "sparkconfigurations",
 "datasets", "dataflows", "pipelines", "triggers", "linkedservices", "credentials"] as $compared
| if ($template[0].resources | length) != ($entries | length) then error("the entries are not the template's") else . end
| ($live | map({key: "\(.type | ascii_downcase)/\(.name | ascii_downcase)", value: .}) | from_entries) as $by_key
| [$template[0].resources, $entries] | transpose[]
| .[0] as $resource
| .[1] as $entry
| ($entry.type | ascii_downcase) as $kind
| $by_key[$entry.key] as $item
| {key: $entry.key}
| if $entry.default then . + {status: "skipped", paths: []}
  elif $item == null then . + {status: "create", paths: []}
  elif ($compared | index($kind)) == null then . + {status: "unknown", paths: [{path: "properties", change: "unknown", why: "\($entry.type) are not compared"}]}
  elif ($item.properties | type) != "object" then . + {status: "unknown", paths: [{path: "properties", change: "unknown", why: "the live definition wasn't listed"}]}
  else
    ($resource.properties // {} | evaluate(0) | remap_references | normalize($kind)) as $mine
    | ($item.properties | normalize($kind)) as $theirs
    # A trigger's runtimeState is read-only in the REST API, but the apply
    # starts the triggers the template marks Started (apply-finish.sh): when
    # the template sets it, a different live state is a change. When it
    # doesn't, the live state is not compared.
    | (if $kind == "triggers" and (($mine | type) != "object" or ($mine | has("runtimeState") | not))
       then [$mine | del(.runtimeState), $theirs | del(.runtimeState)]
       else [$mine, $theirs] end) as [$mine, $theirs]
    | ([diff($mine; $theirs; []) | .path |= show] | unique_by([.path, .change])) as $paths
    | ($paths | map(.change)) as $changes
    | . + {
        status: (if any($changes[]; IN("modified", "added", "removed", "secure")) then "modify"
                 elif any($changes[]; . == "unknown") then "unknown"
                 elif any($changes[]; . == "not-compared") then "secure"
                 else "unchanged" end),
        paths: $paths
      }
  end
