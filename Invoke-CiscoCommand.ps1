#requires -Version 2.0 -Modules Posh-SSH

<#PSScriptInfo

        .VERSION 1.4.2

        .GUID cc2eb093-256f-44db-8260-7239f70f013e

        .AUTHOR Chris Masters

        .COMPANYNAME Chris Masters

        .COPYRIGHT (c) 2018 Chris Masters. All rights reserved.

        .TAGS network cisco ios

        .LICENSEURI 

        .PROJECTURI https://www.powershellgallery.com/profiles/masters274/

        .ICONURI 

        .EXTERNALMODULEDEPENDENCIES Posh-SSH

        .REQUIREDSCRIPTS 

        .EXTERNALSCRIPTDEPENDENCIES 

        .RELEASENOTES
        Issue with handing the IPAddress parameter an array has been resolved. It will now iterate thru the list.

        1.3 - Accepts an SSH session for connection instead of creds.
        1.4 - Removed my debug code. 
        1.4.1 - Had some scoping issues with the SSH Shell Stream variable. Needed to make it Global: before it would work. 
                Added $Timeout parameter for changing the sleep time for waiting on return values.
        1.4.2 - GitHub actions now publishing to PSGallery

        .PRIVATEDATA 

#> 


<#
        .SYNOPSIS
        Run commands on your Cisco iOS device.

        .DESCRIPTION
        Executes commands on a Cisco device as if you were connected to the terminal via SSH.

        .PARAMETER IPAddress
        IP address of the Cisco device you want to execute commands on. This can be a piped list.

        .PARAMETER Command
        Commands that will be executed on the target system. One command per line, typed in quotes, or held
        in a string variable.

        .PARAMETER Credential
        Credentials with rights to run defined commands on the target device.

        .PARAMETER Timeout
        Sleep timeer to wait before checking the stream receive. This should never be shorter than your round trip time (RTT) 
        To find your RTT, you can ping a device. You can find the longest RTT for your company, and set a default parameter value
        for this script.

        .EXAMPLE
        Invoke-CiscoCommand -IPAddress 192.168.1.1 -Command 'show run' -Credential $myCreds
        Returns the running-configuration of Cisco device located at 192.168.1.1

        .EXAMPLE
        $ip = '192.168.1.1','192.168.2.1'
        $ip | Invoke-CiscoCommand -Command 'show run' -Credential $myCreds
        Returns the running-configuration of Cisco device in the array

        .EXAMPLE
        $ip = '192.168.1.1','192.168.2.1'
        
        $cmd = @'
        show version | include uptime
        sh run int vlan 1
        '@

        Invoke-CiscoCommand -IPAddress $ip -Command $cmd -Credential $myCreds
        Returns the running-configuration and uptime of Cisco device in the array

        .NOTES
        Requires Posh-SSH and Core to run.

        .LINK
        https://www.powershellgallery.com/packages/posh-ssh
            

        .INPUTS
        String text for commands, IPaddress object, and PSCredential.

        .OUTPUTS
        Returns the value from commands ran. Using the "Verbose" parameter shows the commands ran, and prompts.
#>


[CmdletBinding(DefaultParameterSetName = 'session')]
Param
(
    [Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'session', HelpMessage = 'Existing Posh-SSH session ID')]
    [object] $Session,

    [Parameter(Mandatory=$true,HelpMessage='Command to be run')]
    [String[]] $Command,
    
    [Parameter(Position = 0,ParameterSetName = 'cred',Mandatory=$true,ValueFromPipeline=$true,HelpMessage='IP address')]
    [Alias('ComputerName','Name','Switch','Router','Host')]
    [IPAddress[]] $IPAddress,
        
    [Parameter(Mandatory=$true,ParameterSetName = 'cred',HelpMessage='Credentials for managed network object')]
    [PSCredential] [System.Management.Automation.Credential()] $Credential,
    
    [Parameter(ParameterSetName = 'cred')]
    [Switch] $AcceptKey, # Passes param along to POSH-SSH if needed

    [Parameter(ParameterSetName = 'cred')]
    [Switch] $Force, # Passes param along to POSH-SSH if needed

    [Int] $Timeout = 180 # How long we sleep in milliseconds when waiting for streams to finish sending data. 
)

Begin {

    function Get-SSHShellStream {

        Param ( 
    
            $Session
        )
    
        $sHostname = $Session.Session.ConnectionInfo.Host
    
        $sUsername = $Session.Session.ConnectionInfo.Username
    
        $ErrorActionPreference = 'SilentlyContinue'
    
        $allStreams = Get-Variable | Where-Object { $_.value -match 'Renci\.SshNet\.ShellStream'}
    
        foreach ($tmpStream in $allStreams) {

            Write-Verbose -Message ('Stream found for {0}' -$tmpStream.Name)
    
            Invoke-Expression -Command ('$tmpObj = ${0}' -f $tmpStream.Name) 
    
            if ($tmpObj.Session.ConnectionInfo.Username -eq $sUsername -and $tmpObj.Session.ConnectionInfo.Host -eq $sHostname) {
    
                return $tmpObj
            }
    
            Remove-Variable -Name tmpObj
        }
    }
}

Process
{
    # Variables
    $strNewLine = "`n"
    $strPattern = '#|^$|configuration...|Current configuration :|^\r\n|^$'
    If (! $Session) {
        $SshSesssionParams = @{
            ComputerName = $IPAddress
            Credential = $Credential
            AcceptKey = $true
            ConnectionTimeout = 90
            ErrorAction = 'Stop'
        }

        If ($Force)
        {
            $SshSesssionParams += @{Force = $Force}
        }

        If ($Force)
        {
            $SshSesssionParams += @{AcceptKey = $AcceptKey}
        }

        $objSessionCisco = New-SSHSession @SshSesssionParams
    }
    else {
       $objSessionCisco = $Session

       Write-Verbose -Message 'Using existing SSH session to connect'
    }

    Foreach ($node in $objSessionCisco)
    {
        $Global:SshStream = Get-SSHShellStream -Session $node

        if (! $Global:SshStream) {
            Write-Verbose -Message 'No stream found'
            $Global:SshStream = New-SSHShellStream -SSHSession $node
        }
        else {

            Write-Verbose -Message 'Stream found'
        }

        # Set terminal length
        $Global:SshStream.WriteLine('terminal length 0')
        $null = $Global:SshStream.Read()

        $arrayCommands = $Command.Split($strNewLine)

        Foreach ($strCiscoCommand in $arrayCommands)
        {
            $Global:SshStream.WriteLine(('{0}' -f $strCiscoCommand))
    
            # Takes a bit for the command to run sometimes
            Start-Sleep -Milliseconds $Timeout
        }
        
        $rawOutput = @()
        
        $boolDataReceived = $false
        
        :waiter While ($true)
        {
            $streamOut = $Global:SshStream.Read() 
            
            If ($boolDataReceived -eq $true -and $streamOut.Length -eq 0 -and -not $(($rawOutput.Split($strNewLine) | Select-Object -Last 1) -eq ''))
            {
                break waiter
            }
            
            If ($streamOut.Length -gt 0) 
            {
                $rawOutput += $streamOut
                $streamOut = $null 
                $boolDataReceived = $true # Watch until we do not receive data anymore
            }

            Start-Sleep -Milliseconds $Timeout
        }
    
        If (!($PSBoundParameters['Verbose'])) 
        {
            $rawOutput = $rawOutput.Split($strNewLine) | Select-String -NotMatch -Pattern $strPattern
        }
        
        $rawOutput
    }

    if ($Credential) {
        # $null = Remove-Variable -Name SshStream
        # $null = Remove-SSHSession -SessionId $($objSessionCisco.SessionId)
    }
}
