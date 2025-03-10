#!/bin/bash

basedir="$(dirname $0)/../.."

query="queries/query-dashboard-by-id.txt"
query_variables="query_variables/query-dashboard-by-id-variables.json"

newrelic_utils::error_exit()
{
  echo "$1" 1>&2
  return 1
}

newrelic_utils::on_error()
{
  if [ "$?" != "0" ]
  then
    newrelic_utils::error_exit
  fi
}

newrelic_utils::call_nr()
{
  local -r query_path="$1"; shift
  local -r query_variable_json="$1"; shift
  local -r api_key="$1"; shift

  [[ -z "${query_path}" ]] && echo "Error: query_path is empty." && return 1
  [[ -z "${query_variable_json}" ]] && echo "Error: query_variable_json is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1

  [[ ! -f "${query_path}" ]] && echo "Error: query_path \"${query_path}\" does not exist." && return 2

  local query=$(jq -c -n --arg content "$(cat "${query_path}")" --argjson variables "${query_variable_json}" '{ query : $content, variables : $variables }')
  newrelic_utils::on_error "Failed to create graphql query!"

  local response="$(curl -s https://api.newrelic.com/graphql \
    -H "Content-Type: application/json" \
    -H "API-Key: $api_key" \
    --data-binary "$query")"
  newrelic_utils::on_error "Connection to New Relic API failed!"
 
  error_count=$(echo "$response" | jq ".errors | length")
  if [ "$error_count" -eq 0 ]; then
    echo "$response" | jq .
  else
    newrelic_utils::error_exit "Found $error_count errors in New Relic API response: $response"
  fi
}

# Create a new dashboard
# $1 - Name of the dashboard file
newrelic_utils::create_dashboard() {
  local -r api_key="$1"; shift
  local -r json_dashboard="$1"; shift

  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 10
  [[ -z "${json_dashboard}" ]] && echo "Error: json_dashboard is empty." && return 10
 
  query="$basedir/queries/mutation-dashboard-create.txt"

  if [[ -f "$query" ]]; then
    newrelic_utils::call_nr "$query" "${json_dashboard}" "$api_key"
  else
    echo "Error: Query file \"${query}\" does not exist"
  fi
}

# Get a dashboard in JSON format
# $1 - Name of the dashboard file
newrelic_utils::get_dashboard() {
  local -r query_variables="$1"; shift
  local -r api_key="$1"; shift
  
  local -r query="$basedir/queries/query-dashboard-by-id.txt"

  newrelic_utils::call_nr "$query" "$query_variables" "$api_key"
}

# Get a dashboard by GUID
# $1 - Name of the dashboard file
newrelic_utils::get_dashboard_by_guid() {
  local -r guid="$1"; shift
  local -r api_key="$1"; shift
  
  local -r query="$basedir/queries/query-dashboard-by-id.txt"
  local -r query_variables="{\"dashboardId\":\"$guid\"}"

  newrelic_utils::call_nr "$query" <(echo "$query_variables") "$api_key"
}


# Get dashboards by tags
# $1 - Tags in JSON format
newrelic_utils::get_dashboards_by_tags() {
  local -r tags="$1"; shift
  local -r api_key="$1"; shift

  query="$basedir/queries/query-dashboard-by-tags.txt"
  newrelic_utils::call_nr "${query}" "${tags}" "${api_key}"
}

# Update a dashboard
# $1 - Name of the dashboard file
newrelic_utils::update_dashboard()
{
  local -r api_key="$1"; shift
  local -r dashboard_guid="$1"; shift
  local -r dashboard="$1"; shift

  local -r query="$basedir/queries/mutation-dashboard-update.txt"
  local -r query_variables=$(jq -n --arg dashboard_guid ${dashboard_guid} --argjson dashboard "${dashboard}" '{ guid : $dashboard_guid, dashboard : $dashboard.dashboard }')

  newrelic_utils::call_nr "${query}" "${query_variables}" "$api_key"
}

newrelic_utils::deploy_dashboards_in_dir() {
  local -r api_key="$1"; shift
  local -r target_dir="$1"; shift
  local -r market="$1"; shift
  local -r env="$1"; shift
  local -r commit_id="$1"; shift
  
  echo "Deploying dashboards in \"$target_dir\" for market \"$market\" in \"$env\" env with commit id \"$commit_id\""
  files="$target_dir/dashboard-*.json"
  for i in $files; do
    echo "Deploying dashboard \"$i\""
    if [[ $(basename $i) =~ dashboard-([a-z]+)-([a-z]+)-(.+).json ]]; then
      m="${BASH_REMATCH[1]}"
      e="${BASH_REMATCH[2]}"
      namespace="${BASH_REMATCH[3]}"
      echo "namespace: $namespace"
      local tags="{\"tags\":[{\"key\":\"project\",\"value\":\"yoda\"},{\"key\":\"product\",\"value\":\"ns-dashboard\"},{\"key\":\"market\",\"value\":\"$market\"},{\"key\":\"env\",\"value\":\"$env\"},{\"key\":\"namespace\",\"value\":\"$namespace\"}]}"
      newrelic_utils::deploy_dashboard "$api_key" "$i" "" "$tags"
    else
      echo "unable to parse string $i"
    fi
  done
}

newrelic_utils::deploy_dashboards() {
  local -r api_key="$1"; shift
  local -r target_dir="$1"; shift
  local -r market="$1"; shift
  local -r env="$1"; shift

  newrelic_utils::deploy_dashboards_in_dir "$api_key" "$target_dir/dashboards/namespace/${market}/${env}" "$market" "$env"
}

# Deploy a dashboard
# $1 - Name of the dashboard file to deploy
# $2 - Name of the argument file
newrelic_utils::deploy_dashboard() {
  local -r api_key="$1"; shift
  local -r dashboard="$1"; shift
  local -r args="$1"; shift
  local -r tags="$1"; shift

  echo "Searching dashboards with tags matching \""$tags"\""
  local -r dashboards=$(newrelic_utils::get_dashboards_by_tags "$tags" "$api_key")

  dashboard_count=$(jq .data.actor.entitySearch.count <<< $dashboards)

  # Import dashboard 
  echo "Found $dashboard_count dashboards with matching tags..."
  if [[ "$dashboard_count" -eq 0 ]]
  then
    echo "Creating a new dashboard"
    local -r response_dashboard=$(newrelic_utils::create_dashboard "$api_key" "$dashboard")
    
    # Tag dashbord with git commit id
    echo "$response_dashboard"
    local -r dashboard_new_guid=$(jq -r .data.dashboardCreate.entityResult.guid <<< $response_dashboard)
    if [[ -n "$dashboard_new_guid" ]]; then
      newrelic_utils::add_tags "$api_key" "$dashboard_new_guid" "$tags"
      echo "Dashboard create completed with guid $dashboard_new_guid..."
      return 0
    else
      echo "Skipping tagging since dashboard not created successfully..."
    fi
  elif [[ "$dashboard_count" -eq 1 ]]
  then
    local -r dashboard_guid=$(jq -r .data.actor.entitySearch.results.entities[0].guid <<< $dashboards)
    echo "Updating existing dashboard with guid \"$dashboard_guid\""
    local -r response_dashboard=$(newrelic_utils::update_dashboard "$api_key" "${dashboard_guid}" "$dashboard")

    # Tag dashbord with git commit id
    echo "$response_dashboard"
    local -r dashboard_new_guid=$(jq -r .data.dashboardUpdate.entityResult.guid <<< $response_dashboard)
    if [[ -n "$dashboard_new_guid" ]]; then
      newrelic_utils::add_tags "$api_key" "$dashboard_new_guid" "$tags"
      echo "Dashboard update completed with guid $dashboard_new_guid..."
      return 0
    else
      echo "Skipping tagging since dashboard not created successfully..."
    fi
  else
    echo "Unable to update dashboard: Number of dashboards ($dashboard_count) is more than 1"
  fi

  return 1
}

query="$basedir/queries/mutation-tags-create.txt"
#query_variables="variables.json"

# Add tags to a dashboard
# $1 - GUID of the dashboard
# $2 - Commit ID of the git repository
# $3 - Name of the argument file
newrelic_utils::add_tags() {
  local -r api_key="$1"; shift
  local -r dashboard_guid="$1"; shift
  local -r tags="$1"; shift

  local commit_id="1234"
  echo "Tagging dashboard[$dashboard_guid] with Commit ID[$commit_id]"

  local multilist_tags=$(newrelic_utils::to_multilist_tags "$tags")
  local -r query_variables=$(jq -c -n --arg dashboard_guid "$dashboard_guid" --argjson tags "$multilist_tags" --argjson commit "[ { \"key\" : \"commitId\", \"values\" : [\"$commit_id\"] }]" '.tags |= $tags | .tags += $commit | .guid |= $dashboard_guid')

  echo "[${query_variables}]"
  newrelic_utils::call_nr "${query}" "${query_variables}" "${api_key}"
}

newrelic_utils::to_multilist_tags() {
  local -r tags="$1"; shift
 
  s=""
  length=$(jq ".tags | length" <<< "$tags")
  for (( i = 0; i < length; i++ )); do
    key=$(jq -r -c ".tags[$i].key" <<< "$tags")
    value=$(jq -r -c ".tags[$i].value" <<< "$tags")
    if [[ "$i" > 0 ]]; then
      s+=","
    fi
    s+="{\"key\":\"$key\",\"values\":[\"$value\"]}"
  done
  echo "[$s]"
}

# Deploy conditions to a policy
# $1 - new relic account ID
# $2 - new relic api key for the account ID
# $3 - target policy name
# $4 - list of notification channels for this policy
# $5 - location of conditions file
newrelic_utils::deploy_policy() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_name="$1"; shift
  local -r conditions_file_path="$1"; shift
  # local -r notification_channels="$1"; shift

# Combine the contents of all JSON files in the directory into a single JSON array
  local conditions=$(jq -s '.' $conditions_file_path/*.json)
  echo "Conditions: $conditions"
  # Ensure the policy_name is quoted
  local -r policies="$(newrelic_utils::get_policies_by_name "$api_key" "$policy_name")"
  local -r -i policy_count=$(jq '.policies | length' <<< $policies)

  [[ -z "${account_id}" ]] && echo "Error: account_id is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${policy_name}" ]] && echo "Error: policy_name is empty." && return 1
  [[ -z "${conditions_file_path}" ]] && echo "Error: conditions is empty." && return 1

  echo "Found $policy_count policies with matching name \""$policy_name"\" in Account ($account_id)"
  if [[ $policy_count -eq 0 ]]
  then    
    echo "Creating a new policy with name \""$policy_name"\""
    local -r policy=$(newrelic_utils::add_policy "${account_id}" "${api_key}" "${policy_name}")
    local -r policy_id=$(jq -r .data.alertsPolicyCreate.id <<< "${policy}")

    #Add Condtiions to the policy
    newrelic_utils::add_conditions "$account_id" "$api_key" "$policy_id" "$conditions"
    # Associate_channel "$policy_id" "$notification_channels"
  elif [[ $policy_count -eq 1 ]]
  then
    policy_id="$(jq -r .policies[0].id <<< $policies)"
    echo "Updating existing policy with ID \"$policy_id\""
    newrelic_utils::delete_conditions_by_policy_id "$account_id" "$api_key" "$policy_id"
    newrelic_utils::add_conditions "$account_id" "$api_key" "$policy_id" "$conditions"
 #   associate_channel "$policy_id" "$notification_channels"
  else
    echo "Unable to update dashboard: Number of policies ($policy_count) is more than 1" >&2
  fi
}

newrelic_utils::deploy_conditions() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift
  local -r conditions_file_path="$1"; shift

  local -r policies="$(newrelic_utils::get_policies_by_name "$api_key" $policy_name)"
  local -r -i policy_count=$(jq '.policies | length' <<< $policies)

  [[ -z "${account_id}" ]] && echo "Error: account_id is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${policy_name}" ]] && echo "Error: policy_name is empty." && return 1
  [[ -z "${conditions}" ]] && echo "Error: conditions is empty." && return 1

  echo "Found $policy_count policies with matching name \""$policy_name"\" in Account ($account_id)"
  if [[ $policy_count -eq 0 ]]
  then
    echo "Creating a new policy with name \""$policy_name"\""
    local -r policy=$(newrelic_utils::add_policy "${account_id}" "${api_key}" "${policy_name}")
    local -r policy_id=$(jq -r .data.alertsPolicyCreate.id <<< "${policy}")

    #Add Condtiions to the policy
    newrelic_utils::add_conditions "$account_id" "$api_key" "$policy_id" "$conditions"
    # Associate_channel "$policy_id" "$notification_channels"
  elif [[ $policy_count -eq 1 ]]
  then
    policy_id="$(jq -r .policies[0].id <<< $policies)"
    echo "Updating existing policy with ID \"$policy_id\""
    newrelic_utils::delete_conditions_by_policy_id "$account_id" "$api_key" "$policy_id"
    newrelic_utils::add_conditions "$account_id" "$api_key" "$policy_id" "$conditions"
 #   associate_channel "$policy_id" "$notification_channels"
  else
    echo "Unable to update dashboard: Number of policies ($policy_count) is more than 1" >&2
  fi
}


newrelic_utils::deploy_policy_with_template() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_name="$1"; shift
  local -r conditions_template_file="$1"; shift
  local -r notification_channels="$1"; shift

  #conditions_file_content=$(jq -r -c ".data.actor.account.alerts.nrqlConditionsSearch | del(.nrqlConditions[].id,.nrqlConditions[].type,.nrqlConditions[].policyId)" "$conditions_template_file")
  conditions_file_content=$(cat "$conditions_template_file")

  #echo "$conditions_file_content" > a.json
  newrelic_utils::deploy_policy "$account_id" "$api_key" "$policy_name" "$conditions_file_content" "$notification_channels"
}

# Add an alert policy 
# $1 - Account ID
# $2 - Name of the alert policy
newrelic_utils::add_policy() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_name="$1"; shift

  local -r policy="PER_CONDITION_AND_TARGET"
  local -r query="$basedir/queries/mutation-policy-create.txt"
  local -r query_variables="{\"policy\":\"$policy\",\"name\":\"$policy_name\",\"accountId\":$account_id}"
 
  [[ -z "${account_id}" ]] && echo "Error: account_id is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${policy_name}" ]] && echo "Error: policy_name is empty." && return 1
  [[ -z "${policy}" ]] && echo "Error: policy is empty." && return 1
  [[ -z "${query}" ]] && echo "Error: query is empty." && return 1
  [[ -z "${query_variables}" ]] && echo "Error: query_variables is empty." && return 1

  newrelic_utils::call_nr "${query}" "${query_variables}" "${api_key}"
}

newrelic_utils::get_conditions() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift

  query="$basedir/queries/query-conditions-by-policy-id.txt"
  query_variables="{ \"accountId\" : ${account_id}, \"policyId\" : \"${policy_id}\"}"

  local -r response=$(newrelic_utils::call_nr "$query" "$query_variables" "$api_key")
  echo "${response}"
}

# Get alert policies by policy name
# $1 - Name of an alert policy
newrelic_utils::get_policies_by_name() {
  local -r api_key="$1"; shift
  local -r policy_name="$1"; shift

  # URL-encode the policy name
  local encoded_policy_name
  encoded_policy_name=$(echo "$policy_name" | jq -s -R -r @uri)

  # Make the API request
  curl -s -X GET "https://api.newrelic.com/v2/alerts_policies.json" \
     -H "Api-Key:$api_key" \
     -G --data-urlencode "filter[name]=$policy_name" \
     --data-urlencode "filter[exact_match]=true"
}

# Get alert policies by policy ID
# $1 - API key
# $2 - ID of an alert policy
newrelic_utils::get_policy_by_id() {
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift

  curl -s -X GET "https://api.newrelic.com/v2/alerts_policies/${policy_id}.json" \
     -H "Api-Key:$api_key"
}

# Associate notification channels with a policy
# $1 - Policy ID
# $2 - Notification channel IDs (comma delimited)
newrelic_utils::associate_channel() {
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift
  local -r channel_ids="$1"; shift

  echo "Associating Policy ($policy_id) with notification channels [$channel_ids]:"
  curl -s -X PUT 'https://api.newrelic.com/v2/alerts_policy_channels.json' \
       -H "Api-Key:$api_key" \
       -H 'Content-Type: application/json' \
       -G -d "policy_id=$policy_id&channel_ids=$channel_ids"
}

# Add an alert condition to a policy
# $1 - Account ID
# $2 - Policy ID
newrelic_utils::add_condition() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift
  local condition="$1"; shift
 
  echo "[${condition}]"
  local query_variables=$(jq -c -n --arg policyId "$policy_id" --argjson accountId "$account_id" --argjson condition "$condition" '{ accountId : $accountId, policyId : $policyId, condition : $condition }')
 
  echo "[${query_variables}]"

  local -r query="$basedir/queries/mutation-condition-create.txt"
  newrelic_utils::call_nr "${query}" "${query_variables}" "${api_key}"
}

# Add alert conditions to a policy
# $1 - Account ID
# $2 - Policy ID
# $3 - Name of the conditions file in JSON format
newrelic_utils::add_conditions() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift
  local -r conditions="$1"; shift

#  local -r conditions="$(cat $conditions_fd)"
  local -r -i condition_count=$(jq '. | length' <<< $conditions)

  [[ -z "${account_id}" ]] && echo "Error: account_id is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${policy_id}" ]] && echo "Error: policy_id is empty." && return 1
  [[ -z "${conditions}" ]] && echo "Error: conditions is empty." && return 1
  [[ -z "${condition_count}" ]] && echo "Error: condition_count is empty." && return 1

  echo "Adding $condition_count conditions to Policy ($policy_id) in Account ($account_id):"
  for (( i = 0; i < condition_count; i++ )); do
    local condition=$(jq -c ".[$i]" <<< "${conditions}")
    newrelic_utils::add_condition "$account_id" "$api_key" "$policy_id" "$condition"
  done
}

# Delete an alert condition of a policy
# $1 - Account ID
# $2 - Condition ID
newrelic_utils::delete_condition() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r condition_id="$1"; shift
  
  query_variables="{\"accountId\":$account_id,\"id\":$condition_id}"
  local query="$basedir/queries/mutation-condition-delete.txt"
  echo "Deleting condition with ID \"$condition_id\"..."
  newrelic_utils::call_nr "${query}" "${query_variables}" "${api_key}"
}

# Delete alert conditions of a policy
# $1 - Account ID
# $2 - Name of the conditions file in JSON format
newrelic_utils::delete_conditions() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r conditions="$1"; shift
  local -r condition_count=$(jq '.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions | length' <<< ${conditions})

  [[ -z "${account_id}" ]] && echo "Error: account_id is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${conditions}" ]] && echo "Error: conditions is empty." && return 1
  [[ -z "${condition_count}" ]] && echo "Error: condition_count is empty." && return 1

  echo "Deleting $condition_count conditions in total:"

  for (( i = 0; i < condition_count; i++ )); do
    local condition_id=$(jq -r -c ".data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[$i].id" <<< ${conditions})
    newrelic_utils::delete_condition "${account_id}" "${api_key}" "${condition_id}"
  done
}

# Delete alert conditions of a policy by policy ID
# $1 - Account ID
# $2 - API Key
# $3 - Policy ID
newrelic_utils::delete_conditions_by_policy_id() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r policy_id="$1"; shift

  echo "Deleting conditions of Policy ($policy_id) in Account ($account_id):"
  newrelic_utils::delete_conditions "$account_id" "$api_key" "$(newrelic_utils::get_conditions $account_id $api_key $policy_id)"
}

# Create an alert policy with graphql mutation using api key and returns the policy id
# $1 - API Key
# $2 - Account ID
# $3 - Policy Name
newrelic_utils::create_policy() {
  local -r api_key="$1"; shift
  local -r policy_file="$1"; shift
  
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${policy_file}" ]] && echo "Error: policy_file is empty." && return 1

  if [[ ! -f "${policy_file}" ]]; then
    echo "Error: policy_file \"${policy_file}\" does not exist." && return 1
  fi

  local policy_file_content
  policy_file_content=$(cat "$policy_file")
  if [[ $? -ne 0 ]]; then
    echo "Error: Failed to read policy file \"${policy_file}\"." && return 1
  fi
  
 
  local response
  
  local query=$(jq -c -n --arg content "$policy_file_content" '{ query : $content }')
  response=$(curl -s https://api.newrelic.com/graphql \
    -H "Content-Type: application/json" \
    -H "API-Key: $api_key" \
    --data-binary "$query")
  if [[ $? -ne 0 ]]; then
    echo "Error: Failed to send request to New Relic API." && return 1
  fi

  
  echo "$response"
}