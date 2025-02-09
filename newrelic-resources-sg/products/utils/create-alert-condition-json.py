import json

# Load the JSON file
with open('policy-template.json') as f:
    data = json.load(f)

# Get the 'nrqlConditions' array
nrql_conditions = data['nrqlConditions']

# Loop through the 'nrqlConditions' array
for i, condition in enumerate(nrql_conditions):
    # Form the alert condition data
    alert_condition_data = {
        "condition": {
            "name": condition['name'],
            "enabled": condition['enabled'],
            "nrql": condition['nrql'],
            "signal": condition['signal'],
            "terms": condition['terms'],
            "valueFunction": "SINGLE_VALUE",
            "violationTimeLimitSeconds": condition['violationTimeLimitSeconds']
        },
        "accountId": 1737703,
        "policyId": int(condition['policyId'])
    }

    # Write the alert condition data to a new JSON file
    with open(f'alert_condition_{i}.json', 'w') as f:
        json.dump(alert_condition_data, f, indent=4)