InstallTools
============

This is a repository of tools to help with the installation of Windows Azure Pack Websites.  Among the tools noted are scripts for helping with offline installation.  


Offline installation instructions
---------------------------------

On a machine with internet connectivity follow these instructions:

1.	Install newest version of Web Platform Installer
2.	In powershell as Administrator run the powershell script named *OfflineWebSitesFeeds.ps1*. The script has 2 optional parameters. 
    *	**$WebSitesFeedLink** is the link pointing to the WebSites0.9.0.xml for the particular version of Windows Azure Pack: Web Sites to be installed, by default this will point to the newest version available. 
    *	**$OfflineFeedsLocation** is the location on the machine that all of the product and product dependencies will be copied to, by default this will be *%SystemDrive%\Offline_Feeds*


From a machine in the isolated network that will host this feed please follow these instructions:

1.	Copy the entire **$OfflineFeedsLocation** folder from the machine with internet connectivity to the isolated machine
2.	Install IIS.  This will be used to host the feed to be used during installation.
3.	In powershell as Administrator run the powershell script *HostWebSitesFeed.ps1*. The script has 2 required parameters.
    * **$OfflineFeedsLocation** is the location of the folder copied from the machine with internet connectivity. 
    * **$HostingLocation** is the directory where to host the feed from.
4.	The script will output a feed to point Web Platform Installer to on the Web Sites Controller role to install the product
5.	Run Web Platform Installer and point the feed to the locally hosted feed.  


When running *OfflineWebSitesFeeds.ps1*, these are the links pointing to older versions of the Websites feed.
* V2 - http://go.microsoft.com/?linkid=9837345
* V2U1 - http://go.microsoft.com/?linkid=9842950
* V2U2 - http://go.microsoft.com/?LinkId=9845550
