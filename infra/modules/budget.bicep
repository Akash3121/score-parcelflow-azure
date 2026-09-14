param budgetName string
param contactEmail string
param amount int
param startDate string

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    amount: amount
    category: 'Cost'
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: [
          resourceGroup().name
        ]
      }
    }
    notifications: {
      Actual_GreaterThan_50_Percent: {
        contactEmails: [
          contactEmail
        ]
        enabled: true
        locale: 'en-us'
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
      }
      Actual_GreaterThan_80_Percent: {
        contactEmails: [
          contactEmail
        ]
        enabled: true
        locale: 'en-us'
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
      }
      Actual_GreaterThan_100_Percent: {
        contactEmails: [
          contactEmail
        ]
        enabled: true
        locale: 'en-us'
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Actual'
      }
    }
  }
}

output budgetId string = budget.id
