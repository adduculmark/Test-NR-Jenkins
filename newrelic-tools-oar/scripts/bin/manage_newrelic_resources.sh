#!/bin/bash

basedir="$(dirname $0)/../.."
source "$basedir/scripts/newrelic/newrelic_utils.sh"

import_from_git_to_newrelic() {
  local -r account_id="$1"; shift
  local -r api_key="$1"; shift
  local -r dashboard_file_path="$1"; shift
  local -r tags="$1"; shift

  [[ -z "${account_id}" ]] && echo "Error: account_id is empty." && return 1
  [[ -z "${api_key}" ]] && echo "Error: api_key is empty." && return 1
  [[ -z "${dashboard_file_path}" ]] && echo "Error: dashboard_file_path is empty." && return 1
  [[ -z "${tags}" ]] && echo "Error: tags is empty." && return 1

  [[ ! -f "${dashboard_file_path}" ]] && echo "Error: dashboard_file_path \"${dashboard_file_path}\" does not exist." && return 2

  local dashboard="$(jq -n --argjson account_id "$account_id" --argjson template "$(cat "$dashboard_file_path")" ". |= { dashboard: \$template, accountId: \$account_id }" )"

  newrelic_utils::deploy_dashboard "$api_key" "${dashboard}" "" "${tags}"
}

function build_newrelic_dashboards_from_template() {
  local -r product_repo_path="$1"; shift
  local -r product_name="$1"; shift

  local -r dashboard_dir="${product_repo_path}/products/${product_name}/dashboard"
  local -r config_dr="${product_repo_path}/products/${product_name}/config"
  local -r dashboard_process_dir="${product_repo_path}/products/common/dashboard"

  [[ -z "${product_repo_path}" ]] && echo "Error: product_repo_path is empty" && return 1
  [[ -z "${product_name}" ]] && echo "Error: product_name is empty" && return 1
  if [[ ! -d "${dashboard_dir}" ]]; then
    echo "dashboard_dir does not exist. Creating directory..."
    mkdir -p "${dashboard_dir}"
  fi
  [[ ! -d "${config_dr}" ]] && echo "Error: config_dr is invalid" && return 1
  [[ ! -d "${dashboard_process_dir}" ]] && echo "Error: dashboard_process_dir is invalid" && return 1

  # Create dashboards from template
  mkdir -p "${dashboard_dir}/generated"
  for i in dev sit uat prod; do
    if [[ -f "${config_dr}/$i.json" ]]; then
      bash "${dashboard_process_dir}/transform.sh" "${config_dr}/$i.json" "${dashboard_process_dir}/template/template.json" "${dashboard_dir}/generated/dashboard-$i.json"
    else
      echo "WARNING: No config file \"config/$i.json\" found in config directory"
    fi
  done
  push_changes_to_feature_branch "${product_repo_path}" "${product_name}"
}

function build_newrelic_policies_from_template() {
  local -r product_repo_path="$1"; shift
  local -r product_name="$1"; shift  
  local -r newrelic_api_key="$1"; shift

  local -r policy_dir="${product_repo_path}/products/${product_name}/policy/generated"  
  local -r config_dir="${product_repo_path}/products/${product_name}/config"
  local -r alert_dir="${product_repo_path}/products/common/alert"

  local -r product_path="${product_repo_path}/products/${product_name}"
  local -r template_path="${product_repo_path}/products/common/alert/template"

  [[ -z "${product_repo_path}" ]] && echo "Error: product_repo_path is empty" && return 1
  [[ -z "${product_name}" ]] && echo "Error: product_name is empty" && return 1
  [[ ! -d "${config_dir}" ]] && echo "Error: config_dir is invalid" && return 1
  [[ ! -d "${product_path}" ]] && echo "Error: product_path is invalid" && return 1
  [[ ! -d "${template_path}" ]] && echo "Error: template_path is invalid" && return 1

  echo "Creating Alert Policy if not exists and getting the response from New Relic..."
 
  bash "${alert_dir}/transform.sh" "${config_dir}/prod.json" "${product_path}" "${template_path}"
    
  push_changes_to_feature_branch "${product_repo_path}" "${product_name}"
}

function push_changes_to_feature_branch() {
  local -r product_repo_path="$1"; shift
  local -r product_name="$1"; shift

  [[ -z "${product_repo_path}" ]] && echo "Error: product_repo_path is empty" && return 1
  [[ -z "${product_name}" ]] && echo "Error: product_name is empty" && return 1

  [[ ! -d "${product_repo_path}/products/${product_name}" ]] && echo "Error: Product directory \"${product_repo_path}/products/${product_name}\" does not exist" && return 10

  echo "Pushing changes to feature branch..."
  
  cd "${product_repo_path}"
  # Add timestamp
  date > .timestamp

  # Push change to repo
  git add .
  git remote -v
  git commit -m "Changes for product ${product_name} on $(date)"

  if git show-ref --quiet refs/heads/feature/OAR-app-dashboard; then
    echo "Branch feature/OAR-app-dashboard already exists. Checking out the branch..."
    git checkout feature/OAR-app-dashboard
  else
    echo "Branch feature/OAR-app-dashboard does not exist. Creating new branch..."
    git branch feature/OAR-app-dashboard
    git checkout feature/OAR-app-dashboard
  fi

  git push -f --set-upstream "${product_repo_path}" "feature/OAR-app-dashboard"
  
  cd -
}

main() {
  local -r action="$1"; shift
  local -r environment="$1"; shift
  local -r environment_suffix="$1"; shift
  local -r resource_type="$1"; shift
  local -r product_repo_path="$1"; shift 
  local -r product_names="$1"; shift
  local -r newrelic_api_key="$1"; shift
  local -r newrelic_account="$1"; shift
  local -r resource_id="$1"; shift

  [[ -z "${action}" ]] && echo "Error: action is empty." && return 10
  [[ -z "${environment}" ]] && echo "Error: environment is empty." && return 10
  [[ -z "${resource_type}" ]] && echo "Error: resource_type is empty." && return 10
  [[ -z "${product_repo_path}" ]] && echo "Error: product_repo_path is empty." && return 10  
  [[ -z "${product_names}" ]] && echo "Error: product_names is empty." && return 10
  [[ ${action} == "IMPORT-FROM-GIT-TO-NEWRELIC" ]] && [[ -z "${newrelic_api_key}" ]] && echo "Error: newrelic_api_key is empty." && return 10

  if [[ "${product_names}" == "ALL" ]]; then
    echo "Product names is ALL. Reading product names from productNames.txt file..."
    while IFS= read -r name; do
      echo "Executing action ${action} for product ${name}..."
      main "${action}" "${environment}" "${environment_suffix}" "${resource_type}" "${product_repo_path}" "${name}" "${newrelic_api_key}" "${newrelic_account}" "${resource_id}"
    done < "$(dirname "$0")/productNames.txt"
    return 0
  else
    local product_name="${product_names}"
  fi

  [[ ! -d "${product_repo_path}/products/${product_name}" ]] && echo "Error: Product directory \"${product_repo_path}/products/${product_name}\" does not exist" && return 10

  local normalised_environment=$(echo "${environment}" | tr '[:upper:]' '[:lower:]')
  local normalised_resource_type=$(echo "${resource_type}" | tr '[:upper:]' '[:lower:]')

  if [[ ! -z "${environment_suffix}" ]]; then
    normalised_environment=$(echo "${environment}-${environment_suffix}" | tr '[:upper:]' '[:lower:]')
    echo "Environment suffix name is non-empty.  Setting environment to \"${normalised_environment}\""
  fi
  if [[ ! -f "${product_repo_path}/products/${product_name}/config/${normalised_environment}.json" ]]; then
    echo "ERROR: No config file \"config/${normalised_environment}.json\" found in config directory"
    return 1
  fi
  
  echo "Executing action ${action}..."
  case "${resource_type}" in
    "DASHBOARD")
      handle_dashboard_action "${action}" "${product_repo_path}" "${product_name}" "${normalised_environment}" "${newrelic_api_key}"
      ;;
    "POLICY")
      handle_policy_action "${action}" "${product_repo_path}" "${product_name}" "${normalised_environment}" "${newrelic_api_key}"
      ;;
    *)
      echo "ERROR: Invalid resource type \"${resource_type}\""
      return 1
      ;;
  esac
  
  return 0
}

handle_dashboard_action() {
  local -r action="$1"; shift
  local -r product_repo_path="$1"; shift
  local -r product_name="$1"; shift
  local -r normalised_environment="$1"; shift
  local -r newrelic_api_key="$1"; shift

  case "${action}" in
    "BUILD-NEWRELIC-RESOURCES-FROM-TEMPLATE")
      build_newrelic_dashboards_from_template "${product_repo_path}" "${product_name}"
      ;;
    "IMPORT-FROM-GIT-TO-NEWRELIC")
      local account_id="$(jq .account_id ${product_repo_path}/products/${product_name}/config/${normalised_environment}.json)"
      local tags="{\"tags\":[{\"key\":\"product\",\"value\":\"${product_name}\"},{\"key\":\"product\",\"value\":\"product-dashboard\"},{\"key\":\"env\",\"value\":\"${normalised_environment}\"}]}"
      import_from_git_to_newrelic "${account_id}" "${newrelic_api_key}" "$(pwd)/${product_repo_path}/products/${product_name}/dashboard/generated/dashboard-${normalised_environment}.json" "${tags}"
      ;;
    *)
      echo "ERROR: Action \"${action}\" is not supported for resource type \"DASHBOARD\"..."
      return 1
      ;;
  esac
}

handle_policy_action() {
  local -r action="$1"; shift
  local -r product_repo_path="$1"; shift
  local -r product_name="$1"; shift
  local -r normalised_environment="$1"; shift
  local -r newrelic_api_key="$1"; shift

  case "${action}" in
    "BUILD-NEWRELIC-RESOURCES-FROM-TEMPLATE")
      build_newrelic_policies_from_template "${product_repo_path}" "${product_name}" "${newrelic_api_key}"
      ;;
    "IMPORT-FROM-GIT-TO-NEWRELIC")
      local account_id="$(jq .account_id ${product_repo_path}/products/${product_name}/config/${normalised_environment}.json)"
      local app_name="$(jq -r .appName ${product_repo_path}/products/${product_name}/config/${normalised_environment}.json)"
      local country_code="$(jq -r .countryCode ${product_repo_path}/products/${product_name}/config/${normalised_environment}.json)"
      app_name=$(echo ${app_name} | tr '[:lower:]' '[:upper:]')
      local policy_name="${country_code} Alert Policy - $(echo ${app_name} | tr -d '\"') (${normalised_environment})"
      local conditions_file_path="${product_repo_path}/products/${product_name}/condition/generated/"
      [[ ! -d "${conditions_file_path}" ]] && echo "Error: Condition folder path \"${conditions_file_path}\" is invalid." && return 1
      newrelic_utils::deploy_policy "${account_id}" "${newrelic_api_key}" "${policy_name}" "${conditions_file_path}"
      ;;
    *)
      echo "ERROR: Action \"${action}\" is not supported for resource type \"POLICY\"..."
      return 1
      ;;
  esac
}

main "$@"