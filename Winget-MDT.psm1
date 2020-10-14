#Requires -Module powershell-yaml
Import-Module "C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1"
function Get-WingetApplication {
    param (
        [Parameter(Mandatory = $true)]
        [string]$packageName
    )
    $repositoryUrlRoot = "https://raw.githubusercontent.com/Microsoft/winget-pkgs/master/manifests/"
    # try {
        # Sorry for the mess.
        # Get the manifest ID and version(Publisher.Name)
        $littleManifest = (winget show $packageName)
        if ($LASTEXITCODE -ne 0) {throw "Couldn't find package $package."}
        $package = ($littleManifest | Select-Object -Skip 1 | Out-String).Split('[')[1].Split(']')[0]
        $version = ($littleManifest | Select-Object -Skip 2 | Out-String | ConvertFrom-Yaml).version
        
        
        # Now we can get the full manifest.
        $publisher,$appName = $package.Split('.')
        $manifestFilePath = $repositoryUrlRoot + ($publisher)+ "/" +($appName) + "/" + $version + ".yaml"
        Write-Host $manifestFilePath
        $manifest = (Invoke-WebRequest $manifestFilePath).Content | Out-String | ConvertFrom-Yaml
        $manifest.appName = $appName
        # Getting around odd manifests. This will probably break when multiple installer types are allowed.
        if ($null -ne $manifest.Installers.InstallerType) 
        {
            $manifest.InstallerType = $manifest.Installers.InstallerType
        }
        return $manifest
    # }
    # catch {
        Write-Host "Unable to find manifest for package $packageName."
        return $null;
    # }
}

function Import-WinGetApplication {
    # This function gets a application from winget and imports it into MDT's application "catalog".
    # Add-PSSnapin Microsoft.BDD.SnapIn
    # 
     param (
        [Parameter(Mandatory = $true)]
        [string]$package,
        [Parameter(Mandatory = $true)]
        [string]$DeploymentSharePath
    )
    $ProgressPreference = 'SilentlyContinue'
    
    try {  
        New-PSDrive -Name "DS001" -PSProvider MDTProvider -Root $DeploymentSharePath
        $manifest = Get-WingetApplication $package
        if ($null -eq $manifest) {return $null}

        # Create directory that MDT will import from
        $publisher = $manifest.Publisher.Split(" ")[0]
        if ($manifest.InstallerType.ToLower() -ne "msi" -and $manifest.InstallerType.ToLower() -ne "wix") { 
            $installerExtension = "exe"
        }
        else {$installerExtension = "msi"}
        $installerFileName = "$($manifest.appName).$($installerExtension)"
        $installerFolder = "TEMP\$($publisher)\$($manifest.Name)"
        $installerPath = "$installerFolder\$installerFileName"
        New-Item -ItemType Directory $installerFolder -Force
        

        # Download the file.
        Invoke-WebRequest $manifest.Installers.Url -OutFile $installerPath
        Write-Host (Get-FileHash $installerPath).Hash.ToLower()
        if ((Get-FileHash $installerPath).Hash.ToLower() -ne (($manifest.Installers.Sha256).ToLower())) { throw "Hashes did not match, stopping."}
        else {(Write-Host "Hashes matched. Ready to start importing.")}
        
        if ($manifest.InstallerType.ToLower() -eq "msi" -or $manifest.InstallerType.ToLower -eq "wix")
        {
            $silentInstallCommand = "msiexec /i $installerFileName /qn"
        }
        elseif ($manifest.InstallerType.ToLower() -eq "inno") {
            $silentInstallCommand = "$installerFileName /VERYSILENT"
        }
        elseif ($manifest.InstallerType.ToLower() -eq "nullsoft") {
            $silentInstallCommand = "$installerFileName /S"
        }
        elseif ($manifest.InstallerType.ToLower() -eq "exe") {
            $silentInstallCommand = "$installerFileName $obj.Switches.Silent"
        }
        else {
            Write-Host "Installer type: ($manifest.InstallerType) currently not supported."
            return 1
        }
        if ($null -eq $manifest.AppMoniker) {
            # Working around that darned edge case.
            $manifest.AppMoniker = $manifest.appName
        }
        $MDTApplicationParameters = @{
            "path" = "DS001:\Applications"
            "enable" = $true
            "name" = $manifest.Name
            "ShortName" = $manifest.AppMoniker
            "Version" = $manifest.Version
            "Publisher" = $manifest.Publisher
            "CommandLine" = $silentInstallCommand
            "WorkingDirectory" = ".\Applications\$publisher\$manifest.Name"
            "ApplicationSourcePath" = "$(pwd)\$installerFolder"
            "DestinationFolder" = "$($publisher)\$($manifest.Name)"
        }
        Import-MDTApplication @MDTApplicationParameters -Verbose
        rm -Recurse -Force TEMP\
        return "Done!"
    }
    catch {
        Write-Host "Error, stopping."
        rm -Recurse -Force TEMP\
        return
    }
}