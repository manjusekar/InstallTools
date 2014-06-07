
param ($offlineFeedsLocation, $hostingLocation)

$WebSitesFeedDirName = "WebSitesFeed"
$WebSitesFeedFileName = "WebSites0.9.0.xml"
$BootstrapperFeedDirName = "BootstrapperFeed"
$BootstrapperFeedFileName = "BootstrapperEntries.xml"

$nsMgr = New-Object System.Xml.XmlNamespaceManager (New-Object System.Xml.NameTable)
$nsMgr.AddNamespace("a", "http://www.w3.org/2005/Atom")

$transcriptLog="HostWebSitesFeed.log"

function LogInfo([string] $text)
{
    $currentTimestamp=(get-date).ToString()
    Write-Host "$currentTimestamp - $text"
    Write-Output "$currentTimestamp - $text" | Out-File -FilePath $transcriptLog -append
}

function GetComputerFQDN
{
    try
    {
        $ipHostEntry = [System.Net.Dns]::GetHostEntry($env:ComputerName)
        return $ipHostEntry.HostName
    }
    catch [System.Net.Sockets.SocketException]
    {
        LogInfo "Socket exception encountered while retrieving the machine's FQDN. Exception details:"
        LogInfo $_.Exception.ToString()
        LogInfo "Warning:  $env:ComputerName will be used instead of the fully qualified name"
        return $env:ComputerName
    }
    catch [System.ArgumentException]
    {
        LogInfo "Exception encountered while retrieving the machine's FQDN. Exception details:"
        LogInfo $_.Exception.ToString()
        LogInfo "Warning:  $env:ComputerName will be used instead of the fully qualified name"
        return $env:ComputerName
    }
}

function GetAbsoluteLink ([string] $relativePath, [string] $httpPathToDirWithFeedXml)
{
    # WebPI offlines the files with characters like space and % in the file names, but 
    # the relative path it generates doesn't have these characters escaped. So, we need to escape 
    # the HTTP URLs (once) for things to work.
    $escapedUriStr = [System.Uri]::EscapeUriString($httpPathToDirWithFeedXml + $relativePath)

    $uri = New-Object System.Uri ($escapedUriStr)
    return $uri.AbsoluteUri;
}

function ConvertRelativeLinksToAbsoluteLinks ([string] $feedFilePath, [string] $httpPathToDirWithFeedXml)
{
    if (!$httpPathToDirWithFeedXml.EndsWith("/"))
    {
        $httpPathToDirWithFeedXml = $httpPathToDirWithFeedXml + "/"
    }
    
    [xml] $feedXml = Get-Content $feedFilePath
    
    foreach ($entry in $feedXml.feed.entry)
    {
        if ($entry.images.relativeIconUrl -ne $null)
        {
            $entry.images.icon = [string] (GetAbsoluteLink $entry.images.relativeIconUrl $httpPathToDirWithFeedXml)
            $removedNode = $entry.images.RemoveChild($entry.images.SelectSingleNode("a:relativeIconUrl", $nsMgr))
        }
        
        foreach ($installer in $entry.installers.installer)
        {
            if ($installer.relativeEulaURL -ne $null)
            {
                $installer.eulaURL = [string] (GetAbsoluteLink $installer.relativeEulaURL $httpPathToDirWithFeedXml)
                $removedNode = $installer.RemoveChild($installer.SelectSingleNode("a:relativeEulaURL", $nsMgr))
            }
            
            foreach ($installerFile in $installer.installerFile)
            {
                if ($installerFile.relativeInstallerURL -ne $null)
                {
                    $installerFile.installerURL = [string] (GetAbsoluteLink $installerFile.relativeInstallerURL $httpPathToDirWithFeedXml)
                    $removedNode = $installerFile.RemoveChild($installerFile.SelectSingleNode("a:relativeInstallerURL", $nsMgr))
                }
            }
        }
    }

    LogInfo "Overwriting the original feed file with a new feed with absolute links..."
    $feedXml.Save($feedFilePath)
}

function GetHash([string] $filePath)
{
    if (![System.IO.Path]::IsPathRooted($filePath))
    {
        $curDir = (Get-Location).Path
        $filePath = [System.IO.Path]::Combine($curDir, $filePath)
    }

    if (![System.IO.File]::Exists($filePath))
    {
        Write-Error "The file $filePath was not found.";
        return
    }

    $sha1 = New-Object System.Security.Cryptography.SHA1Managed
    $allBytes = [System.IO.File]::ReadAllBytes($filePath)
    $hashBytes = $sha1.ComputeHash($allBytes)
    $hashWithDashes = [System.BitConverter]::ToString($hashBytes)
    return $hashWithDashes.Replace("-", [string]::Empty)
}

function ReplaceMsiPropertyValue ([string] $propertiesStr, [string] $propertyName, [string] $newPropertyValue)
{
    $startPos = $propertiesStr.IndexOf("$propertyName=")
    $endPos = $propertiesStr.IndexOf(" ", $startPos)
    
    $precedingPart = $propertiesStr.Substring(0, $startPos)
    $followingPart = ""    
    if ($endPos -ne -1)
    {
        $followingPart = $propertiesStr.Substring($endPos)
    }
    
    return $precedingPart + "$propertyName=$newPropertyValue" + $followingPart
}

function ReplaceCommandLineArgValue ([string] $commandLine, [string] $argName, [string] $newArgValue)
{
    $commandLineParts = $commandLine.Split(@(' '), [StringSplitOptions]::RemoveEmptyEntries)
    for ($i = 0; $i -lt $commandLineParts.Length; ++$i)
    {
        if ($commandLineParts[$i] -eq "-$argName")
        {
            $commandLineParts[$i + 1] = $newArgValue
            break
        }
    }
    
    return [string]::Join(" ", $commandLineParts)
}

function PatchBootstrapperFeed ([string] $bootstrapperFeedPath, [string] $webSitesFeedUrl, [string] $webSitesFeedHash)
{
    # Under the bootstrapper entry,
    # ./installers/installer/installCommands/msiInstall/properties starts with:
    #       WEBSITES_FEED=http://go.microsoft.com/?linkid=9837345 FEED_HASH=826363D220C6EF0D8DBF36FA63172A339D16C268
    # ./installers/installer/installCommands/cmdline[0]/commandLineArguments contains:
    #       -mainFeed http://go.microsoft.com/?linkid=9837345 -mainFeedFileName WebSites0.9.0.xml  -mainFeedHash 826363D220C6EF0D8DBF36FA63172A339D16C268 
    [xml] $bootstrapperXml = Get-Content $bootstrapperFeedPath
    $bootstrapperEntry = $bootstrapperXml.feed.SelectSingleNode('a:entry[a:productId = "HostingPrimaryControllerBootstrapper_v2"]', $nsMgr)
    
    $msiInstallNode = $bootstrapperEntry.installers.installer.installCommands.msiInstall
    [string] $msiPropertiesStr = $msiInstallNode.properties
    
    $msiPropertiesStr = ReplaceMsiPropertyValue $msiPropertiesStr "WEBSITES_FEED" $webSitesFeedUrl
    $msiPropertiesStr = ReplaceMsiPropertyValue $msiPropertiesStr "FEED_HASH" $webSitesFeedHash
    
    $msiInstallNode.properties = $msiPropertiesStr
    
    $cmdLineNode = $bootstrapperEntry.installers.installer.installCommands.cmdline[0]
    [string] $commandLine = $cmdLineNode.commandLineArguments
    
    $commandLine = ReplaceCommandLineArgValue $commandLine "mainFeed" $webSitesFeedUrl
    $commandLine = ReplaceCommandLineArgValue $commandLine "mainFeedHash" $webSitesFeedHash
    
    $cmdLineNode.commandLineArguments = $commandLine
    
    LogInfo "Updating the Bootstrapper feed XML file..."
    $bootstrapperXml.Save($bootstrapperFeedPath)
}

function AddMimeType ([string] $extensionStr, [string] $mimeType)
{
    $mimeConfig = Get-WebConfiguration //staticContent/* | where {$_.fileExtension -eq $extensionStr}
    if ($mimeConfig -eq $null) 
    {
        Add-WebConfiguration //staticContent -Value @{fileExtension=$extensionStr;mimeType=$mimeType}
    }
}

# MAIN BODY OF THE SCRIPT STARTS HERE
if (![System.IO.Path]::IsPathRooted($hostingLocation))
{
    # If $hostingLocation is not an absolute path, convert it to an absolute path - this 
    # is needed because we will be writing to files under this location, and those APIs/cmdlets 
    # work predictably with absolute paths.
    $curDir = (Get-Location).Path
    $hostingLocation = [System.IO.Path]::Combine($curDir, $hostingLocation)
}

# Create the directory if it doesn't exist.
[System.IO.Directory]::CreateDirectory($hostingLocation)

# Copy the feed repositories to the hosting location.
$webSitesFeedSourcePath = Join-Path $offlineFeedsLocation $WebSitesFeedDirName
$bootstrapperFeedSourcePath = Join-Path $offlineFeedsLocation $BootstrapperFeedDirName

LogInfo "Copying WebSites Feed to the hosting location $hostingLocation..."
Copy-Item $webSitesFeedSourcePath -Destination $hostingLocation -Recurse
LogInfo "Copying Bootstrapper-Entry Feed to the hosting location $hostingLocation..."
Copy-Item $bootstrapperFeedSourcePath -Destination $hostingLocation -Recurse

$hostedWebSitesFeedPath = Join-Path $hostingLocation $WebSitesFeedDirName
$hostedBootstrapperFeedPath = Join-Path $hostingLocation $BootstrapperFeedDirName

# TODO: It would be nice to install core IIS components as well, so that the user doesn't have to pre-install IIS.
LogInfo "Trying to install IIS-ManagementScriptingTools..."
Invoke-Command -ScriptBlock { & dism.exe /Online /Enable-Feature /FeatureName:IIS-ManagementScriptingTools /all }

if ($lastExitCode -ne 0)
{
    LogInfo "Error hit when trying to install IIS-ManagementScriptingTools. Continuing..."
}

# Expose the hosted feeds through IIS.
Import-Module WebAdministration
LogInfo "Creating a WebApplication to expose WebSites feed..."
$webSitesFeedApp = Get-WebApplication -Name "WebSitesFeed"
if ($webSitesFeedApp -eq $null)
{
    New-WebApplication -Name "WebSitesFeed" -Site "Default Web Site" -PhysicalPath $hostedWebSitesFeedPath -ApplicationPool DefaultAppPool -Force
}

LogInfo "Creating a WebApplication to expose the WebSites Bootstrapper Entry feed..."
$bootstrapperFeedApp = Get-WebApplication -Name BootstrapperFeed
if ($bootstrapperFeedApp -eq $null)
{
    New-WebApplication -Name "BootstrapperFeed" -Site "Default Web Site" -PhysicalPath $hostedBootstrapperFeedPath -ApplicationPool DefaultAppPool -Force
}

# Add MIME type needed for downloading .msp files for offline installations
AddMimeType ".msp" "application/octet-stream"

# Add MIME type needed for downloading .msu files for offline installations
AddMimeType ".msu" "application/octet-stream"

# Add MIME type needed for downloading .tmp files
AddMimeType ".tmp" "text/plain"

# Add MIME type needed for downloading files without any extension
AddMimeType "." "text/plain"

# Replace relative links with absolute links in the WebSites feed XML.
$filePathToWebSitesFeedXml = Join-Path $hostedWebSitesFeedPath "feeds\latest\$WebSitesFeedFileName"
$computerFqdn = GetComputerFQDN
$httpPathToDirWithWebSitesFeedXml = "http://$computerFqdn/WebSitesFeed/feeds/latest/"
ConvertRelativeLinksToAbsoluteLinks $filePathToWebSitesFeedXml $httpPathToDirWithWebSitesFeedXml

# Get the hash of the updated WebSites feed XML.
$newWebSitesFeedHash = GetHash $filePathToWebSitesFeedXml

# Patch Bootstrapper-Entry feed XML.
$filePathToBootstrapperFeedXml = Join-Path $hostedBootstrapperFeedPath "feeds\latest\$BootstrapperFeedFileName"
$httpPathToWebSitesFeedXml = $httpPathToDirWithWebSitesFeedXml + $WebSitesFeedFileName
PatchBootstrapperFeed $filePathToBootstrapperFeedXml $httpPathToWebSitesFeedXml $newWebSitesFeedHash

$httpPathToBootstrapperFeed = "http://$computerFqdn/BootstrapperFeed/feeds/latest/$BootstrapperFeedFileName"
LogInfo "You should be able to install WebSites by pointing Web Platform Installer to $httpPathToBootstrapperFeed (as your main feed)."
