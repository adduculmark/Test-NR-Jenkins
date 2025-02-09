pipeline {
    agent { label 'macOSX' }
    options { disableConcurrentBuilds() }
    environment {
        SHARED_LIB = "$WORKSPACE/OAR-scripts"
    }

    stages {
        stage('Parameters Setup') {
            steps {
                script {
                    properties([[$class: 'JiraProjectProperty', siteName: 'https://jira.ap.manulife.com/'], parameters([
                        choice(choices: ['BUILD-NEWRELIC-RESOURCES-FROM-TEMPLATE', 'IMPORT-FROM-GIT-TO-NEWRELIC'], description: 'Action to perform', name: 'ACTION'), 
                        [$class: 'CascadeChoiceParameter', choiceType: 'PT_SINGLE_SELECT', description: 'Name of the environment ', filterLength: 1, filterable: false, name: 'ENVIRONMENT', randomName: 'choice-parameter-197183925882287', referencedParameters: 'ACTION', script: [$class: 'GroovyScript', fallbackScript: [classpath: [], sandbox: true, script: ''], script: [classpath: [], sandbox: true, script: '''if (ACTION.equals("BUILD-FROM-TEMPLATE-TO-DASHBOARDS")) { return ["N/A"] } else { return ["DEV","SIT","UAT","PROD"] }''']]], 
                        string(name: 'ENVIRONMENT_SUFFIX', defaultValue: '', description: 'The optional suffix to attach to the environment name.  E.g., if suffix is stg and environment is uat then it would become uat-stg', trim: true),
                        choice(name: 'RESOURCE_TYPE', choices: ['DASHBOARD','POLICY'], description: 'Resource type'),
                        choice(name: 'REPOSITORY_NAME', choices: ['newrelic-resources-sg'], description: 'Name of the repository'),           
                        choice(name: 'PRODUCT_NAMES', choices: ['ALL','sg-app-cat','sg-app-cc','sg-app-chatbot','sg-app-core-domain','sg-app-core-capability','sg-app-core-payment','sg-app-core-processing','sg-app-core-workflow','sg-app-cws','sg-app-econtract','sg-app-findex','sg-app-fusion','sg-app-lms','sg-app-m360','sg-app-m365','sg-app-move','sg-app-mq','sg-app-ppas','sg-app-rbj','sg-app-sgcas','sg-app-hnw'], description: 'Product Names (TESTING)'),
                        string(name: 'NEWRELIC_API_KEY', defaultValue: '', description: 'New Relic API key - Minimum APM Key required (Required for import only)', trim: true)
                    ]), [$class: 'JobLocalConfiguration', changeReasonComment: '']])
                }
            }
        }    

        stage('Checkout Scripts Repository') {
            steps {
                checkout([
                    $class: 'GitSCM', 
                    branches: [[name: 'refs/heads/main']], // Change to your branch if needed
                    doGenerateSubmoduleConfigurations: false, 
                    extensions: [[$class: 'RelativeTargetDirectory', relativeTargetDir: 'newrelic-tools-sg']],
                    userRemoteConfigs: [[
                        url: 'https://github.com/adduculmark/esm-re-nr-jenkins-automated-condition-dashboard.git', 
                        credentialsId: 'ETS_OAR_TEST_CRED' // Updated to use the new credentials
                    ]]
                ])
            }
        }

        stage('Checkout Market Repository') {
            steps {
                checkout([
                    $class: 'GitSCM', 
                    branches: [[name: 'refs/heads/main']], // Change to your branch if needed
                    doGenerateSubmoduleConfigurations: false, 
                    extensions: [[$class: 'RelativeTargetDirectory', relativeTargetDir: "${REPOSITORY_NAME}"]],
                    userRemoteConfigs: [[
                        url: "https://github.com/adduculmark/${REPOSITORY_NAME}.git", 
                        credentialsId: 'ETS_OAR_TEST_CRED' // Updated to use the new credentials
                    ]]
                ])
            }
        }

        stage('Executing Pipeline') {
            steps {
                script {
                    sh """
                      set +x
                      bash newrelic-tools-sg/scripts/bin/manage_newrelic_resources.sh '${ACTION}' '${ENVIRONMENT}' '${ENVIRONMENT_SUFFIX}' '${RESOURCE_TYPE}' '${REPOSITORY_NAME}' '${PRODUCT_NAMES}' '${NEWRELIC_API_KEY}'
                    """
                }
            }
        }
    }

    post { 
        always { 
            cleanWs()
        }
    }
}
