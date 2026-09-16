metadata description = 'Shared user-defined types for the Foundry agent platform templates.'

@export()
@description('A model deployment on the Foundry account. The name is what agent overlays reference as model.deploymentName.')
type modelDeploymentType = {
  @description('Deployment name referenced by agent overlays as model.deploymentName.')
  @minLength(2)
  @maxLength(64)
  name: string

  @description('Model identifier, for example gpt-4o or gpt-4o-mini.')
  modelName: string

  @description('Model version. Pin explicitly; do not rely on the service default.')
  modelVersion: string

  @description('Deployment SKU, for example GlobalStandard, DataZoneStandard or Standard.')
  skuName: string

  @description('Throughput in thousands of tokens per minute.')
  @minValue(1)
  capacity: int
}
