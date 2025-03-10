#!/bin/bash

main() {
  local -r config_path="$1"; shift
  local -r template_path="$1"; shift
  local -r target_path="$1"; shift

  curr_dashboard_path="temp_dashboard.json"
  next_dashboard_path=""  

  local -r env=$(jq -r -c .env "$config_path")
  local -r appName=$(jq -r -c .appName "$config_path")
  local -r countryCode=$(jq -r -c .countryCode "$config_path")

  jq -n --argjson config "$(cat $config_path)" --slurpfile template $template_path ". |= {}
                        | .name |= \$template[0].name
                        | .name |= sub(\"ENV\"; \"$env\")
                        | .name |= sub(\"appName\"; \"$appName\")
                        | .name |= sub(\"countryCode\"; \"$countryCode\")
                        | .description |= \$template[0].description
                        | .permissions |= \"PUBLIC_READ_ONLY\"
                        | .pages |= \$template[0].pages
                        | .pages[].widgets[].rawConfiguration.nrqlQueries[]?.accountId |= \$config.account_id
                        " > $curr_dashboard_path
  
  local -r patterns=$(jq -r -c .patterns "$config_path")
  local -r patternSize=$(echo $patterns | jq -c '. | length')
  local patternCount=0

  echo $patterns | jq -c '.[]' | while read pattern ; do
    echo $pattern > tmp.json
    matchingName=($(jq -r '.match' tmp.json))
    replacedByName=($(jq -r '.replacedBy' tmp.json))
    rm tmp.json

    next_dashboard_path="${matchingName}.json"
    
    jq -n --slurpfile template $curr_dashboard_path ". |= {}
                        | .name |= \$template[0].name
                        | .description |= \$template[0].description
                        | .permissions |= \$template[0].permissions
                        | .pages |= \$template[0].pages
                        | .pages[].widgets[].rawConfiguration.nrqlQueries[]?.query |= gsub(\"$matchingName\"; \"$replacedByName\")
                        " > $next_dashboard_path

    rm $curr_dashboard_path  
    curr_dashboard_path=$next_dashboard_path

    patternCount=$((patternCount+1)) 
    if [ $patternCount -eq $patternSize ]
    then
      mv $curr_dashboard_path $target_path      
    fi
  done

  echo "Dashboard has been transformed successfully into $target_path"
}

main "$@"