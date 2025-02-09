#!/bin/bash

create_policy() {
  local -r config="$1"
  local -r env="$2"
  local -r appName="$3"
  local -r countryCode="$4"
  local -r policy_template_path="$5"
  local -r policy_target_path="$6"

  echo "config: $config"
  echo "env: $env"
  echo "appName: $appName"
  echo "countryCode: $countryCode"
  echo "policy_template_path: $policy_template_path"
  echo "policy_target_path: $policy_target_path"

  # Temporary file for the transformed policy
  local curr_policy_path="policy_mutation.txt"
  new_policy_target_path="${policy_target_path}/$curr_policy_path"
  echo "curr_policy_path: $curr_policy_path"
  echo "new_policy_target_path: $new_policy_target_path"

  # Sed command to replace the ENV, appName, and countryCode in the policy template
  sed -e "s/ENV/$env/g" -e "s/appName/$appName/g" -e "s/{{countryCode}}/$countryCode/g" "$policy_template_path" > "$curr_policy_path"
  echo "Policy template has been transformed"

  # Move the transformed policy to the target path
  # Create the target directory if it does not exist
  mkdir -p "$(dirname "$new_policy_target_path")"
  # Create an empty file if it does not exist
  touch "$new_policy_target_path"
  mv "$curr_policy_path" "$new_policy_target_path"
  echo "Policy has been transformed successfully into $new_policy_target_path"
}

create_condition() {
  local -r config="$1"
  local -r condition_template_path="$2"
  local -r condition_target_path="$3"
  local -r countryCode="$4"

  # Temporary file for the transformed condition
  local curr_condition_path="temp_condition.json"
  local next_condition_path="temp_condition_next.json"
  # Extract patterns from the config
  local -r patterns=$(jq -r -c .patterns <<< "$config")
  local -r patternSize=$(jq -c '. | length' <<< "$patterns")
  local patternCount=0

  echo "Testing Patterns $patterns"
  echo "$condition_template_path"
  # Delete all the files in the condition target path if it exists
  rm -rf "$condition_target_path"/*
  
  # Loop through each condition template file
  for file in "$condition_template_path"/*.json; do
      # Get the file name
      fileName=$(basename "$file")
      echo "Processing File Name: $fileName"
      
      jq -n --argjson config "$config" --slurpfile template "$file" '
      $template[0]
      | .name |= gsub("{{countryCode}}"; $config.countryCode)
      | .name |= gsub("appName"; $config.appName)
      ' > "$curr_condition_path"

      echo "Set Current Condition Path: $curr_condition_path"

      echo "Looping Patterns"        
      # Loop through each pattern and replace the pattern in the condition file
      for pattern in $(jq -c '.patterns[]' <<< "$config"); do
          # Increment the pattern count
          patternCount=$((patternCount + 1))

          # Extract the match and replacedBy values from the pattern
          local match=$(jq -r -c .match <<< "$pattern")
          local replacedBy=$(jq -r -c .replacedBy <<< "$pattern")

          # Check if match or replacedBy is null or empty
          if [ -z "$match" ] || [ -z "$replacedBy" ]; then
            echo "Error: match or replacedBy is null or empty in pattern: $pattern"
            continue
          fi     
          
          jq -n --slurpfile template "$curr_condition_path" --arg match "$match" --arg replacedBy "$replacedBy" '
          $template[0] | .nrql.query |= gsub($match; $replacedBy)
          ' > "$next_condition_path"

          # Create the target directory if it does not exist
          mkdir -p "$condition_target_path"

          mv "$next_condition_path" "$curr_condition_path"
          # If all patterns are processed, move the final condition to the target path
            if [ $patternCount -eq $patternSize ]; then
            # Check if .nrql.query is an empty string
            if jq -r '.nrql.query' "$curr_condition_path" | grep -q "''"; then
              echo "Condition file ${curr_condition_path} has an empty .nrql.query, deleting the file."
              rm "$curr_condition_path"
            else
              mv "$curr_condition_path" "${condition_target_path}/${fileName}"
              echo "Condition has been transformed successfully into ${condition_target_path}/${fileName}"
            fi
            patternCount=0
            fi

      done        
  done
}

main() {
  # Declare the path for the config, policy template, and target
  local -r config_path="$1"; shift
  local -r product_path="$1"; shift
  local -r template_path="$1"; shift
  # local -r policy_id="$1"; shift

  local policy_template_path="${template_path}/mutation_create_policy.txt"
  local policy_target_path="${product_path}/policy/generated"
  local condition_template_path="${template_path}/condition"
  local condition_target_path="${product_path}/condition/generated"

  # Read the config file
  local -r config=$(cat "$config_path")

  # Extract environment, appName, and countryCode from the config
  local -r env=$(jq -r -c .env <<< "$config")
  local -r appName=$(jq -r -c .appName <<< "$config")
  local -r countryCode=$(jq -r -c .countryCode <<< "$config")
  
  # Call the create_policy function
  create_policy "$config" "$env" "$appName" "$countryCode" "$policy_template_path" "$policy_target_path"

  # Call the create_condition function
  create_condition "$config" "$condition_template_path" "$condition_target_path" "$countryCode"

}

# Call the main function with all script arguments
main "$@"