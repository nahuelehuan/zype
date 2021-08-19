#usage 
#C:\Users\fnavalo\Nahuel\Git\ALL\ALL.DeployRSG.ps1 DEV azuredeploy_nahuel_1 xxxxx-xxx-xxx-xxx-xxxx C:\stgacc.arm.json C:\stgacc.para.json

Param(
    [Parameter(Mandatory = $true)][string] $Environment, # DEV/LAB/PRD
    [Parameter(Mandatory = $true)][string] $deployName,
    [Parameter(Mandatory = $true)][string] $SubscriptionId,
    [Parameter(Mandatory = $true)][string] $TemplateFile,
    [Parameter(Mandatory = $true)][string] $JsonParameters,
    [switch] $ValidateOnly    
)

#Error Actions
$ErrorActionPreference = 'Stop'

#Set Context
Write-Warning "Setting AzContext"
Write-Warning "context = Set-AzContext -SubscriptionId $($SubscriptionId)"
$context = Set-AzContext -SubscriptionId $SubscriptionId


#Deployment RSG at subscription level

Write-Warning "ARM Deployment"

if ($ValidateOnly) {
    $ErrorMessages = Format-ValidationOutput (Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
            -TemplateFile $TemplateFile `
            -TemplateParameterFile $JsonParameters  `
            @OptionalParameters)
    if ($ErrorMessages) {
        Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
    }
    else {
        Write-Output '', 'Template is valid.'
    }
}
else {
    # Create or update the resource group using the specified template file and template parameters file
    $deployOutput = New-AzDeployment -Location "South Central US" -TemplateFile $TemplateFile -Verbose -ErrorVariable ErrorMessages -TemplateParameterFile $JsonParameters #-TemplateVersion "2.1" -Tag @{"key1"="value1"; "key2"="value2";}
}
