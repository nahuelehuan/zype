#Conect to Azure#
#Connect-AzAccount

#How To Run
#'./Createrunasnahuel.ps1' LAB  9542f032-8fc3-466b-adf1-bfec0b80d683 fnavalo nahuel.avalos southcentralus 

param(
    #VSTS data
    [Parameter(Mandatory = $true)][string]$env,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$userprincipal,
    [Parameter(Mandatory = $true)][string]$ResourceGroupOMS,
    [Parameter(Mandatory = $true)][string]$Location
 )

#Populate the glonbal variables
if ($env -eq "LAB") {
    $ObjectIDWorker = Get-AzADUser -ObjectId "$($userprincipal)@labdomain.com" | Select-Object -Expandproperty Id
}else{
    $ObjectIDWorker = Get-AzADUser -ObjectId "$($userprincipal)@proddomain.com" | Select-Object -Expandproperty Id
}
$AutomationAccountName = "$($userprincipal)dfltaa"
$keyVaultName = "$($userprincipal)dfltkv"
$ApplicationDisplayName = "RunAsAcc-$userprincipal"


#stand on subscription
Get-AzSubscription -SubscriptionId $SubscriptionId | Select-AzSubscription

##############################################################################################################
# create keyvault
$GetKeyVault = Get-AzKeyVault -ResourceGroupName $ResourceGroupOMS -VaultName $keyVaultName | Select-Object -ExpandProperty VaultName

if (!$GetKeyVault) {
    Write-Warning -Message "Key Vault not found. Creating the Key Vault $keyVaultName"
    $keyValut = New-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $ResourceGroupOMS -Location $Location
    if (!$keyValut) {
        Write-Error -Message "Key Vault $keyVaultName creation failed. Please fix and continue"
        return
    }
    Start-Sleep -s 15     
}

#### granting SP access to KeyVault
Set-AzKeyVaultAccessPolicy -ResourceGroupName $ResourceGroupOMS -VaultName $keyVaultName -ObjectId $ObjectIDWorker -PermissionsToCertificates get,list,delete,create -PermissionsToKeys get,list,delete,create -PermissionsToSecrets get,list,delete,set -PermissionsToStorage get,list,delete,set

##############################################################################################################

[String] $SelfSignedCertPlainPassword = [Guid]::NewGuid().ToString().Substring(0, 8) + "!"
$KeyVaultName = Get-AzKeyVault -ResourceGroupName $ResourceGroupOMS -VaultName $keyVaultName | Select-Object -ExpandProperty VaultName
[int] $NoOfMonthsUntilExpired = 36
  

##############################################################################################################
#Populate certificate policy

$CertificateName = "RunAsCertificate-$userprincipal"
$CertifcateAssetName = $CertificateName
$PfxCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".pfx")
$PfxCertPlainPasswordForRunAsAccount =  ConvertTo-SecureString $SelfSignedCertPlainPassword -AsPlainText -Force
$CerCertPathForRunAsAccount = Join-Path $env:TEMP ($CertificateName + ".cer")

#Generate the cert in the kv
Write-Output "Generating the cert using Keyvault $keyVaultName"
$certSubjectName = "cn=" + $certificateName
$Policy = New-AzKeyVaultCertificatePolicy -SubjectName $certSubjectName -IssuerName "Self" -KeyType "RSA" -KeyUsage "DigitalSignature" -ValidityInMonths $noOfMonthsUntilExpired -RenewAtNumberOfDaysBeforeExpiry 20 -KeyNotExportable:$False -ReuseKeyOnRenewal:$False
$AddAzureKeyVaultCertificateStatus = Add-AzKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName -CertificatePolicy $Policy 
  
While ($AddAzureKeyVaultCertificateStatus.Status -eq "inProgress") {
    Start-Sleep -s 10
    $AddAzureKeyVaultCertificateStatus = Get-AzKeyVaultCertificateOperation -VaultName $keyVaultName -Name $certificateName
}
 
if ($AddAzureKeyVaultCertificateStatus.Status -ne "completed") {
    Write-Error -Message "Key vault cert creation is not sucessfull and its status is: $status.Status" 
}

#import the certificate 
$cert = Get-AzKeyVaultCertificate -VaultName $keyVaultName -Name $certificateName
$AzKeyVaultCertificatSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $cert.Name
$secretValueText = '';
$ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzKeyVaultCertificatSecret.SecretValue)
try {
    $secretValueText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
}
$AzKeyVaultCertificatSecretBytes = [Convert]::FromBase64String($secretValueText)
$certCollection = new-object System.Security.Cryptography.X509Certificates.X509Certificate2
$certCollection.Import($AzKeyVaultCertificatSecretBytes, "", "Exportable,PersistKeySet")

#write to file
$type = [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx
$protectedCertificateBytes = $certCollection.Export($type, $SelfSignedCertPlainPassword)
[System.IO.File]::WriteAllBytes($PfxCertPathForRunAsAccount, $protectedCertificateBytes)

#Export the .cer file 
$certBytes = $cert.Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
[System.IO.File]::WriteAllBytes($CerCertPathForRunAsAccount, $certBytes)


##############################################################################################################
# Create Service Principal
Write-Output "Creating service principal..."

# Use Key credentials and create AAD Application
$KeyId = [Guid]::NewGuid() 
$Application = New-AzADApplication -DisplayName $ApplicationDisplayName -HomePage ("http://" + $applicationDisplayName) -IdentifierUris ("http://" + $KeyId)
$keyValue = [System.Convert]::ToBase64String($certCollection.GetRawCertData())
$startDate = Get-Date
$endDate = (Get-Date $certCollection.GetExpirationDateString()).AddDays(-1)
New-AzADAppCredential -ApplicationId $Application.ApplicationId -CertValue $keyValue -StartDate $startDate -EndDate $endDate 
New-AzADServicePrincipal -ApplicationId $Application.ApplicationId -SkipAssignment

# Sleep here for a few seconds to get,list,delete,createow the service principal application to become active (should only take a couple of seconds normally)
Start-Sleep -s 15


#Assigning contributor role to runasaccount-userprincipal
Write-Output "Assigning Role..."
$NewRole = $null
$Retries = 0;
While ($NewRole -eq $null -and $Retries -le 6) {
    New-AzRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $Application.ApplicationId -scope ("/subscriptions/" + $subscriptionId) #-ErrorAction SilentlyContinue
    Start-Sleep -s 10
    $NewRole = Get-AzRoleAssignment -ServicePrincipalName $Application.ApplicationId -ErrorAction SilentlyContinue
    $Retries++;
}

##############################################################################################################

Write-Output "Creating Automation account"

$GetAutomationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupOMS -Name $AutomationAccountName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty AutomationAccountName

if (!$GetAutomationAccount) {
    Write-Warning -Message "Automation Account not found. Creating $AutomationAccountName"
    $automationaccount = New-AzAutomationAccount -ResourceGroupName $ResourceGroupOMS -Name $AutomationAccountName -Location $Location
    if (!$automationaccount) {
        Write-Error -Message "Automation Account $keyVaultName creation failed. Please fix and continue"
        return
    }
    Start-Sleep -s 15     
}

##############################################################################################################
    
Write-Output "Creating Certificate in the Asset..."
$CertPassword = $PfxCertPlainPasswordForRunAsAccount
Remove-AzAutomationCertificate -ResourceGroupName $ResourceGroupOMS -automationAccountName $AutomationAccountName -Name $certifcateAssetName -ErrorAction SilentlyContinue
$PfxCert = New-AzAutomationCertificate -ResourceGroupName $ResourceGroupOMS -automationAccountName $AutomationAccountName -Path $PfxCertPathForRunAsAccount -Name $certifcateAssetName -Password $CertPassword -Exportable
##############################################################################################################

# Populate the ConnectionFieldValues
$ConnectionTypeName = "AzureServicePrincipal"
$ConnectionAssetName = "AzureRunAsConnection"
$ApplicationId = $Application.ApplicationId 
$SubscriptionInfo = Get-AzSubscription -SubscriptionId $SubscriptionId
$TenantID = (Get-AzContext).Tenant.ID
$Thumbprint = $PfxCert.Thumbprint
$ConnectionFieldValues = @{"ApplicationId" = $ApplicationID; "TenantId" = $TenantID; "CertificateThumbprint" = $Thumbprint; "SubscriptionId" = $SubscriptionId} 

# Create a Automation connection asset named AzureRunAsConnection in the Automation account. This connection uses the service principal.
Write-Output "Creating Connection in the Asset..."
$ConnectionFieldValues = @{"ApplicationId" = $ApplicationID; "TenantId" = $TenantID; "CertificateThumbprint" = $Thumbprint; "SubscriptionId" = $SubscriptionId} 
Remove-AzAutomationConnection -ResourceGroupName $ResourceGroupOMS -automationAccountName $AutomationAccountName -Name $connectionAssetName -Force #-ErrorAction SilentlyContinue
New-AzAutomationConnection -ResourceGroupName $ResourceGroupOMS -automationAccountName $AutomationAccountName -Name $connectionAssetName -ConnectionTypeName $connectionTypeName -ConnectionFieldValues $connectionFieldValues 
##############################################################################################################

Write-Output "RunAsAccount Creation Completed..."
This paste expires in <1 hour. Public IP access. Share whatever you see with others in seconds with Context.Terms of ServiceReport this
