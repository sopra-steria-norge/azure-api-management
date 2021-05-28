#Function for importing APIs to APIM
function Import-API($jsonFile) {
	$apiVersionSetId = $jsonFile.info.title
	$apiVersionSetId = $apiVersionSetId -replace "[^0-9a-zA-Z_]", "-";

	$apiVersironNumber = $jsonFile.info.version.split(".")[0]
	$apiVersionId = "Version $apiVersironNumber"
	Write-Host "Api version: $apiVersionId"
	$apiRevisionId = $jsonFile.info.version.split(".")[1]
	Write-Host "API rev id: $apiRevisionId"

	$apiVersionSet = New-AzApiManagementApiVersionSet -Context $ApiMgmtContext -ApiVersionSetId $apiVersionSetId -Name $jsonFile.info.title -Scheme Header -HeaderName "x-ms-version"

	if ($jsonFile.openapi -notlike $null){
		$specificationFormat = "OpenApi" 
	} else {
		Write-Host "Unable to determine API specification format" 
	}
				
	if ($specificationFormat -like "OpenApi") {
		try {
			$basePath = $jsonFile.info.'x-suffix'
		}
		catch{
			$serviceUrl = [System.Uri]$jsonFile.servers[0].url
			$basePath = $serviceUrl.AbsolutePath
		}
	} 

	$api = Import-AzApiManagementApi -Context $ApiMgmtContext -SpecificationFormat $specificationFormat -SpecificationPath $apiFilePath -Path $basePath -ApiVersionSetId $apiVersionSetId -ApiVersion $apiVersionId -ApiRevision $apiRevisionId
	$productId = $jsonFile.info.'x-productid'

	Write-Host "API ID: $api.ApiId, Product ID: $productId"
	if ($productId -notlike $null -and $productId -notlike ""){
		Add-AzApiManagementApiToProduct -Context $ApiMgmtContext -ProductId $productId -ApiId $api.ApiId
	} else {
		Write-Host "Did not find Product ID in specification" 
	}

    $policyFile = $apiFilePath.Replace(".json", "")
    $policyFileExtension = "_policy.xml"
    $policyFile = "$policyFile$policyFileExtension"
    Write-Host "Policy file: $policyFile"

	if (Test-Path "$sourceFolder/$policyFile" -PathType Leaf) {
        Write-Host "Adding policies to API"
        Set-AzApiManagementPolicy -Context $ApiMgmtContext -ApiId $api.ApiId -PolicyFilePath "APIs/$policyFile"
    } else {
        Write-Host "Policy file not found"
    }
}

#Getting APIM env variables 
$resourceGroup = $env:APIM_RG
$apimInstance = $env:APIM_Name

#Move to source folder on build server
cd $env:BUILD_SOURCESDIRECTORY/APIs
$sourceFolder = "$env:BUILD_SOURCESDIRECTORY/APIs"

Write-Host "Triggered from $env:BUILD_SOURCEBRANCH"

#Set context (used in import calls)
if ($env:BUILD_SOURCEBRANCH -like "refs/heads/main") {
	$ApiMgmtContext = New-AzApiManagementContext -ResourceGroupName $resourceGroup -ServiceName $apimInstance
	#Get git hash from last time pipeline was run
	$oldHash = $env:LASTGITHASH_MAINBRANCH
}

#Get hash from the latest git commit
$newHash = git log --oneline -1 --pretty=format:%H

#Loop throught changed files since last run
$gitChanges = $(git diff --name-status $oldHash $newHash) -replace "^[\s>]" , "" -replace "\s+" , ","

Write-Host "Old hash: $oldHash, New hash: $newHash"
Write-Host "Git changes: "
Write-Host $gitChanges

foreach ($line in $gitChanges) {
	$modificationType = $line.Split(",")[0]
	$apiFilePath = $line.Split(",")[1]

	#Ignore files not in \API folder
	if ($apiFilePath.Split("/")[0] -ne "APIs" )
	{
		Write-Host "Ignoring file: $apiFilePath"
		continue
	}
	
	$fileType = $apiFilePath.Split(".")[-1]
	
	$filePath = "$sourceFolder\$apiFilePath"
	$filePath = $filePath.Replace("/", "\")
	
	Write-Host "Handling API: $filePath"
	
	if ($modificationType -eq "A") 
	{
		if ($fileType -eq "json") 
		{
			Write-Host "Importing Json format API: $filePath"
			$jsonFile = Get-Content -Raw -Path $filePath | ConvertFrom-Json
			
			Import-API $jsonFile
		}
		else 
		{
			Write-Host "Unsupported file type: $fileType..."
		}
	} 
	elseif ($modificationType -eq "M") 
	{	
		$jsonFile = Get-Content -Raw -Path $filePath | ConvertFrom-Json
		$existingApi = Get-AzApiManagementApi -Context $ApiMgmtContext -Name $jsonFile.info.title
		if ($existingApi.ApiId -ne $null) 
		{
		    $existingApi = $existingApi[-1] #Get the latest version of the API
			$completeVersion = $jsonFile.info.version 
			$jsonVersion = [int]$completeVersion.Split(".")[0]
			$jsonRevision = [int]$completeVersion.Split(".")[1]
						
			#If revision/version number is empty in APIM, they will get value 0 here..			
			$apiVersion = [int]$existingApi.ApiVersion.split(" ")[1] #version: "Version X"
			$apiRevision = [int]$existingApi.ApiRevision
			
			$apiVersironNumber = $jsonFile.info.version.split(".")[0]
			$apiVersionId = "Version $apiVersironNumber"
			$apiRevisionId = $jsonFile.info.version.split(".")[1]			
			
			if ($jsonVersion -gt $apiVersion) 
			{
				Import-API $jsonFile
			}
			elseif ($jsonRevision -gt $apiRevision) 
			{
				Write-Host "Will create new revision.."
				
				$newRevision = $jsonRevision
				
				#Create new revision based on current
				$newApiRevision = New-AzApiManagementApiRevision -Context $ApiMgmtContext -ApiId $existingApi.ApiId -ApiRevision $newRevision -SourceApiRevision $apiRevision 
			
				#Upload API schema to revision: 
				New-AzApiManagementApiSchema -Context $ApiMgmtContext -ApiId $newApiRevision.ApiId -SchemaDocumentContentType "application/json" -SchemaDocumentFilePath "APIs/$apiFilePath"
			
				#Release revision:
				New-AzApiManagementApiRelease -Context $ApiMgmtContext -ApiId $newApiRevision.ApiId -ApiRevision $newApiRevision.ApiRevision
			}
			else 
			{
				#Do nothing
			}
		}
		else 
		{
			#Did not find existing API in APIM, will import from scratch
			Write-Host "Did not find existing API.. Importing Json format API: $filePath"
			$jsonFile = Get-Content -Raw -Path $filePath | ConvertFrom-Json
			Import-API $jsonFile
		}		
	}
}

#Replace hash in Pipeline Variable with latest hash
$env:AZURE_DEVOPS_EXT_PAT = $env:SYSTEM_ACCESSTOKEN
az pipelines variable-group variable update --group-id 1 --name "lastGitHash_mainBranch" --value $newHash
