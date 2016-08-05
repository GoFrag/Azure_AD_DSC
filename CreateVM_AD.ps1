param
(
   
   $rgname ="MoreSmaple",
   $location = "West Europe",
   $subnetName="Subnet1",
   $storageAccountName="99912storage",
   $fullPathToDSC, 
   $compName="myvm1",
   $primaryadm="uneidel",
   $primaryadmpwd="Passw0rd!",
   $backupadm="notuneidel",
   $backupadmpwd="Passw0rd!",
   $vipName="faafaa", 
   $domainName="acdc.com"
)



$containerName = "$($storageAccountName)container"
$internalvipName="vip1"

# Create New Resource Group
New-AzureRmResourceGroup -Name $rgName -Location $location
# Create New Storage Account for DSC and VHD
New-AzureRmStorageAccount -ResourceGroupName $rgName -Name $storageAccountName -Location $location -SkuName Standard_LRS
$storage = Get-AzureRmStorageAccount -ResourceGroupName $rgName -Name $storageAccountName

# Create new Container for DSC - Public
New-AzureStorageContainer -Name $containerName -Permission Container -Context $storage.Context

# Upload DSC to Contaner
Publish-AzureVMDscConfiguration -ConfigurationPath $fullPathToDSC -ContainerName $containerName  -StorageContext $storage.Context


# Create Public Address
$vip = New-AzureRmPublicIpAddress -ResourceGroupName $rgname `
   -Name $internalvipName -Location $location -AllocationMethod Dynamic `
   -DomainNameLabel $vipName

#Create network
$subnet = New-AzureRmVirtualNetworkSubnetConfig -Name $subnetName `
   -AddressPrefix “10.0.64.0/24”

$vnet = New-AzureRmVirtualNetwork -Name “VNET” `
   -ResourceGroupName $rgname `
   -Location $location -AddressPrefix “10.0.0.0/16” -Subnet $subnet

$subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name $subnetName `
   -VirtualNetwork $vnet

# Create LB 
$feIpConfig = New-AzureRmLoadBalancerFrontendIpConfig -Name "FEIP" `
   -PublicIpAddress $vip


$inboundNATRule1 = New-AzureRmLoadBalancerInboundNatRuleConfig -Name "RDP1" `
   -FrontendIpConfiguration $feIpConfig `
   -Protocol TCP -FrontendPort 3441 -BackendPort 3389

$inboundNATRule2 = New-AzureRmLoadBalancerInboundNatRuleConfig -Name "RDP2"`
   -FrontendIpConfiguration $feIpConfig `
   -Protocol TCP -FrontendPort 3442 -BackendPort 3389


$beAddressPool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name "LBBE"


$alb = New-AzureRmLoadBalancer -ResourceGroupName $rgName `
   -Name "ALB" -Location $location -FrontendIpConfiguration $feIpConfig `
   -InboundNatRule $inboundNATRule1,$inboundNatRule2 `
    -BackendAddressPool $beAddressPool 
   

# Create NIC
$nic1 = New-AzureRmNetworkInterface -ResourceGroupName $rgName `
   -Name "nic1" -Subnet $subnet -Location $location `
   -LoadBalancerInboundNatRule $alb.InboundNatRules[0] `
   -LoadBalancerBackendAddressPool $alb.BackendAddressPools[0]

# Prep
$blobPath = "vhds/$($compName)Disk.vhd"
$osDiskUri = $storage.PrimaryEndpoints.Blob.ToString() + $blobPath

# Create administrator Credentials
$primarypasswd = ConvertTo-SecureString $primaryadmpwd -AsPlainText -Force
$secondarypasswd = ConvertTo-SecureString $backupadmpwd -AsPlainText -Force
$pcred = New-Object System.Management.Automation.PSCredential ($primaryadm, $primarypasswd)
$scred = New-Object System.Management.Automation.PSCredential ($backupadm, $secondarypasswd)



# Create VM 
$vmconfig = New-AzureRMVMConfig -Name $compName -VMSize "Standard_A1"
$vmconfig = Set-AzureRmVMOperatingSystem -VM $vmconfig -Windows -ComputerName $compName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
$vmconfig = Set-AzureRmVMSourceImage -VM $vmconfig -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2012-R2-Datacenter -Version "latest"
$vmconfig = Set-AzureRMVMOSDisk -Name "$($compName)Disk" -Caching ReadWrite -VM $vmconfig -VhdUri $osDiskUri -CreateOption FromImage
$vmconfig = Add-AzureRmVMNetworkInterface -Id $nic1.Id  -VM $vmconfig 
New-AzureRMVM -VM $vmconfig -Location $location -ResourceGroupName $rgName

# Execute after successful privisioning the VM
$config = @{};
$config.Add("domainCred", $pcred);
$config.Add("safemodeAdministratorCred", $scred);
$config.Add("domainName",$domainName);
Set-AzureRmVMDscExtension -ResourceGroupName $rgName -VMName $compName -ArchiveBlobName "ActiveDirectoryInstall.ps1.ZIP" `
                          -ArchiveStorageAccountName $storageAccountName -ConfigurationName "ActiveDirectoryInstall" `
                           -ConfigurationArgument $config -Version "2.17"  -ArchiveContainerName $containerName 


