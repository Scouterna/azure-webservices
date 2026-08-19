// =============================================================================
// alerts.bicep — Azure-side alerting for the audit log.
//
// Deployed to the durable infra RG alongside the workspace. These are OUTSIDE the
// cluster on purpose: they must still fire when the cluster is the problem, and
// they do not depend on the in-cluster Alertmanager gap.
//
// What each rule catches and what it costs: docs/decisions.md entry 9.
//
// Deploy:
//   az deployment group create -g webservices-infra \
//     -f infra/alerts.bicep -p workspaceName=<name> alertEmail=<address>
// =============================================================================

@description('Name of the audit workspace (infra/loganalytics.bicep). Must already exist.')
param workspaceName string

@description('Address that receives these alerts. A shared infra mailbox, not a person.')
param alertEmail string

@description('Azure region for the query rule (action groups and Activity Log alerts are global).')
param location string = resourceGroup().location

@description('Resource tags.')
param tags object = {
  ManagedBy: 'Bicep'
  Initiative: 'webservices-cluster'
  Purpose: 'audit-alerts'
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'audit-alerts'
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'auditalert'
    enabled: true
    emailReceivers: [
      {
        name: 'infra'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Someone deleting the diagnostic setting or the workspace is the tamper case: it
// stops collection silently, and only the Activity Log records that it happened.
resource tamperAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'audit-pipeline-deleted'
  location: 'Global'
  tags: tags
  properties: {
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          anyOf: [
            {
              field: 'operationName'
              equals: 'Microsoft.Insights/diagnosticSettings/delete'
            }
            {
              field: 'operationName'
              equals: 'Microsoft.OperationalInsights/workspaces/delete'
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

// The daily cap stops ingestion and the workspace still reports healthy, so this is
// the only thing that makes a blinded audit log visible. docs/decisions.md 9.
resource capAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'audit-ingestion-capped'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    enabled: true
    displayName: 'Audit log ingestion stopped (daily cap reached)'
    severity: 1
    scopes: [
      workspace.id
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: '_LogOperation | where Category == "Ingestion" and Detail has "daily limit"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

@description('Action group receiving both alerts.')
output actionGroupId string = actionGroup.id
