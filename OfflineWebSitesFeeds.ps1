param($WebSitesFeedLink, $OfflineFeedsLocation = [System.Environment]::ExpandEnvironmentVariables("%SystemDrive%\Offline_Feeds"))

$WebPiCmd = [System.Environment]::ExpandEnvironmentVariables("%ProgramW6432%\Microsoft\Web Platform Installer\WebpiCmd.exe")
$MainWebPiFeedUrl = "http://go.microsoft.com/?linkid=9823756"
$WebSitesFeedFileName = "WebSites0.9.0.xml"
$BootstrapperFeedFileName = "BootstrapperEntries.xml"
$WebPiCmdLog="CreateOfflineFeed.log"
$transcriptLog="OfflineWebSitesFeed.log"
$nsMgr = New-Object System.Xml.XmlNamespaceManager (New-Object System.Xml.NameTable)
$nsMgr.AddNamespace("a", "http://www.w3.org/2005/Atom")

function LogInfo([string] $text)
{
    $currentTimestamp=(get-date).ToString()
    Write-Host "$currentTimestamp - $text"
    Write-Output "$currentTimestamp - $text" | Out-File -FilePath $transcriptLog -append
}

function GetCurrentWebSitesFeedFileName ([string] $mainFeedPath)
{
    [xml] $mainFeedXml = Get-Content $mainFeedPath
    $mainFeedEntry = $mainFeedXml.feed.SelectSingleNode('a:entry[a:productId = "HostingPrimaryControllerBootstrapper_v2"]', $nsMgr)
    
    $msiInstallNode = $mainFeedEntry.installers.installer.installCommands.msiInstall
    [string] $propertiesStr = $msiInstallNode.properties
    
    $webSitesFeedPos = $propertiesStr.IndexOf("WEBSITES_FEED=")
    $startPos = $propertiesStr.IndexOf("http", $webSitesFeedPos)
    $endPos = $propertiesStr.IndexOf(' ', $startPos)
    if($endPos -eq -1)
    {
        return $propertiesStr.Substring($startPos)
    }
    return $propertiesStr.Substring($startPos, $endPos - $startPos)
}

function DownloadFromHttpLink ([string] $link, [string] $localDestinationFilePath) {
    $webClient = $null
    
    try {
        # Download the file from the link.
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($link, $localDestinationFilePath)
        return $true
    }
    catch [System.Exception] {
        $exceptionMessage = $_.Exception.Message
        
        # Sometimes when an exception occurs, the real error message seems to be hidden inside the InnerException, 
        # so get that message too if it's available.
        if ($_.Exception.InnerException -ne $null) {
            $exceptionMessage += " " + $_.Exception.InnerException.Message
        }
        
        LogInfo "Exception encountered when trying to download file from $link."
        LogInfo "Error Message: $exceptionMessage"
        return $false
    }
    finally {
        if ($webClient -ne $null) {
            $webClient.Dispose
        }
    }
}

function DownloadFromHttpLinkViaProxy ([string] $link, [string] $localDestinationFilePath) {
    $webClient = $null
    
    try {
        # Download the file from the link.
        $webClient = New-Object System.Net.WebClient
        
        # If there is a proxy configured at the system level, use those proxy settings. For some reason, 
        # System.Net.WebClient doesn't seem to be doing so automatically.
        $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        if ($systemProxy -ne $null) {
            # Get the proxy address. We have to do this in a roundabout way since IWebProxy doesn't expose 
            # the proxy address.
            $proxyUri = $systemProxy.GetProxy($link)
            
            # If there is no proxy configured in Internet Settings, it looks like we're still sometimes 
            # getting a non-null $systemProxy object. In such cases, the above GetProxy() call has been 
            # observed to return the same Uri that was supplied as input. Check to avoid setting an 
            # invalid proxy in such cases.
            if ($proxyUri -ne $link) {
                LogInfo "Using the proxy address $proxyUri"
                $proxy = New-Object System.Net.WebProxy ($proxyUri, $true)
                $proxy.UseDefaultCredentials = $true
                
                $webClient.Proxy = $proxy
            }
        }
        
        $webClient.DownloadFile($link, $localDestinationFilePath)
        return $true
    }
    catch [System.Exception] {
        $exceptionMessage = $_.Exception.Message
        
        # Sometimes when an exception occurs, the real error message seems to be hidden inside the InnerException, 
        # so get that message too if it's available.
        if ($_.Exception.InnerException -ne $null) {
            $exceptionMessage += " " + $_.Exception.InnerException.Message
        }
        
        LogInfo "Exception encountered when trying to download file from $link."
        LogInfo "Error Message: $exceptionMessage"
        return $false
    }
    finally {
        if ($webClient -ne $null) {
            $webClient.Dispose
        }
    }
}

function DownloadFeedFileWithRetries ([string] $linkToFeed, [string] $localFeedFileName) {
    [string] $currentDirectory = Get-Location
    [string] $localFeedFilePath = [System.IO.Path]::Combine($currentDirectory, $localFeedFileName)
    [int] $maxRetryCount = 3
    
    for ($i = 0; $i -lt $maxRetryCount; ++$i) {
        # We assume here that the given link is an HTTP link.
        if ((DownloadFromHttpLink $linkToFeed $localFeedFilePath) -eq $true) {
            LogInfo "Feed file downloaded successfully from $linkToFeed to $localFeedFilePath."
            
            # Return the local path that the file has been downloaded to.
            return $localFeedFilePath
        }
    }
    
    for ($i = 0; $i -lt $maxRetryCount; ++$i) {
        # We assume here that the given link is an HTTP link.
        if ((DownloadFromHttpLinkViaProxy $linkToFeed $localFeedFilePath) -eq $true) {
            LogInfo "Feed file downloaded successfully from $linkToFeed."
            
            # Return the local path that the file has been downloaded to.
            return $localFeedFilePath
        }
    }
    
    LogInfo "Failed to download feed file despite retries. Exiting..."
    exit -1
}

function FileNameContainsBadChars ([string] $filePath)
{
    $fileName = [System.IO.Path]::GetFileName($filePath)
    
    # TODO: Update with more 'bad' characters as we find them.
    return $fileName.Contains(" ")
}

function GetSanitizedFilePath ([string] $filePath)
{
    $fileName = [System.IO.Path]::GetFileName($filePath)
    $newFileName = $fileName.Replace(" ", "_")
    return $filePath.Replace($fileName, $newFileName)
}

function SanitizeRelativeUrlAndMoveFileIfNeeded ([string] $relativeUrl)
{
    $sanitizedUrl = GetSanitizedFilePath $relativeUrl
    
    if (FileNameContainsBadChars $relativeUrl)
    {
        # Write-Host "Fixing bad path: $relativeUrl"
        $prevPath = Join-Path $feedFileDirPath $relativeUrl
        $sanitizedPath = Join-Path $feedFileDirPath $sanitizedUrl
        Move-Item $prevPath $sanitizedPath
    }
    
    return $sanitizedUrl
}

function FixLinksWithBadChars ([string]$feedRootPath, [string] $feedFileName)
{
    $feedFilePath = Join-Path $feedRootPath "feeds\latest\$feedFileName"
    $feedFileDirPath = Join-Path $feedRootPath "feeds\latest"
    
    [xml] $feedXml = Get-Content $feedFilePath
    
    foreach ($entry in $feedXml.feed.entry)
    {
        if ($entry.images.relativeIconUrl -ne $null)
        {
            [string] $sanitizedUrl = SanitizeRelativeUrlAndMoveFileIfNeeded $entry.images.relativeIconUrl
            $entry.images.relativeIconUrl = $sanitizedUrl
        }
        
        foreach ($installer in $entry.installers.installer)
        {
            if ($installer.relativeEulaURL -ne $null)
            {
                [string] $sanitizedUrl = SanitizeRelativeUrlAndMoveFileIfNeeded $installer.relativeEulaURL
                $installer.relativeEulaURL = $sanitizedUrl
            }
            
            foreach ($installerFile in $installer.installerFile)
            {
                if ($installerFile.relativeInstallerURL -ne $null)
                {
                    [string] $sanitizedUrl = SanitizeRelativeUrlAndMoveFileIfNeeded $installerFile.relativeInstallerURL
                    $installerFile.relativeInstallerURL = $sanitizedUrl
                }
            }
        }
    }
    
    $feedXml.Save($feedFilePath)
}

if (![System.IO.File]::Exists($WebPiCmd))
{
    LogInfo "Error: Web PI is not installed."
    exit -1
}

if(!$WebSitesFeedLink)
{
    $mainFeedPath = DownloadFeedFileWithRetries $MainWebPiFeedUrl "WebProductList.xml"
    $WebSitesFeedLink = GetCurrentWebSitesFeedFileName $mainFeedPath
    rm $mainFeedPath
}

$localWebSitesFeedFilePath = DownloadFeedFileWithRetries $WebSitesFeedLink $WebSitesFeedFileName

$webSitesFeedOfflinePath = Join-Path $OfflineFeedsLocation "WebSitesFeed"
Invoke-Command -ScriptBlock { & $WebPiCmd /offline /products:"HostingController,HostingFrontEndRole,HostingWebRole,HostingPublishingRole,HostingManagementServerRole,HostingAdministration,HostingFileServerRole,HostingWebPlatformInstaller" /Path:$webSitesFeedOfflinePath /XML:$WebSitesFeedFileName /Log:"$WebPiCmdLog" /Language:en }

if($lastExitCode -ne 0)
{
    # Offlining the WebSites Feed failed.
    LogInfo "ERROR: Offlining the WebSites Feed failed."
    exit -1
}

$bootstrapperFeedOfflinePath = Join-Path $OfflineFeedsLocation "BootstrapperFeed"
Invoke-Command -ScriptBlock { & $WebPiCmd /offline /products:"HostingPrimaryControllerBootstrapper_v2" /Path:$bootstrapperFeedOfflinePath /XML:$MainWebPiFeedUrl /Log:"$WebPiCmdLog" /Language:en }

if($lastExitCode -ne 0)
{
    # Offlining the Bootstrapper Entry failed.
    LogInfo "ERROR: Offlining the Bootstrapper Entry failed."
    exit -1
}

$bootstrapperFeedFilesDir = Join-Path $bootstrapperFeedOfflinePath "feeds\latest\"
$bootstrapperFeedFiles = Get-ChildItem $bootstrapperFeedFilesDir -Filter *.xml
$bootstrapperFeedXmlPath = $bootstrapperFeedFiles[0].FullName
Move-Item $bootstrapperFeedXmlPath (Join-Path $bootstrapperFeedFilesDir $BootstrapperFeedFileName)

FixLinksWithBadChars $webSitesFeedOfflinePath $WebSitesFeedFileName
FixLinksWithBadChars $bootstrapperFeedOfflinePath $BootstrapperFeedFileName

LogInfo "Offline feeds have been created at $OfflineFeedsLocation."

rm $localWebSitesFeedFilePath